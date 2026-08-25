#!/bin/bash

set -u

echo "========================================"
echo "Block Ads Update"
echo "========================================"

# --------------------------------------------------
# Configuration
# --------------------------------------------------

PREFIX="Block ads"

MAX_LIST_SIZE=1000
MAX_LISTS=100
MAX_RETRIES=10

DOMAIN_FILE="oisd_small_domainswild2.txt"
CHUNK_PREFIX="oisd_small_domainswild2.txt."

API_TOKEN="${API_TOKEN:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"

BASE_URL="https://api.cloudflare.com/client/v4"
LISTS_URL="${BASE_URL}/accounts/${ACCOUNT_ID}/gateway/lists"
RULES_URL="${BASE_URL}/accounts/${ACCOUNT_ID}/gateway/rules"

# --------------------------------------------------
# Error handling
# --------------------------------------------------

error() {
    echo ""
    echo "========================================"
    echo "ERROR"
    echo "========================================"
    echo "$1"
    echo ""
    rm -f "${CHUNK_PREFIX}"*
    exit 1
}

# --------------------------------------------------
# Check required environment variables
# --------------------------------------------------

if [[ -z "$API_TOKEN" ]]; then
    error "API_TOKEN GitHub secret is missing."
fi

if [[ -z "$ACCOUNT_ID" ]]; then
    error "ACCOUNT_ID GitHub secret is missing."
fi

echo "Cloudflare account: ${ACCOUNT_ID:0:6}******"

# --------------------------------------------------
# Headers
# --------------------------------------------------

AUTH_HEADERS=(
    -H "Authorization: Bearer ${API_TOKEN}"
    -H "Content-Type: application/json"
)

# --------------------------------------------------
# Download latest OISD list
# --------------------------------------------------

echo "Downloading latest OISD domain list..."

curl -sSfL \
    --retry "$MAX_RETRIES" \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 120 \
    "https://small.oisd.nl/domainswild2" \
    | grep -vE '^\s*(#|$)' \
    > "$DOMAIN_FILE" \
    || error "Failed to download OISD domain list."

if [[ ! -s "$DOMAIN_FILE" ]]; then
    error "Downloaded domain list is empty."
fi

total_lines=$(wc -l < "$DOMAIN_FILE")

echo "Downloaded ${total_lines} domains."

if (( total_lines > MAX_LIST_SIZE * MAX_LISTS )); then
    error "Domain list contains ${total_lines} domains, exceeding the maximum of $((MAX_LIST_SIZE * MAX_LISTS))."
fi

# --------------------------------------------------
# Check whether list changed
# --------------------------------------------------

if git diff --quiet -- "$DOMAIN_FILE"; then
    echo "The domains list has not changed."
    echo "Nothing to update."
    exit 0
fi

echo "The domains list has changed."

# --------------------------------------------------
# Calculate required lists
# --------------------------------------------------

total_lists=$((total_lines / MAX_LIST_SIZE))

if (( total_lines % MAX_LIST_SIZE != 0 )); then
    total_lists=$((total_lists + 1))
fi

echo "Cloudflare lists required: ${total_lists}"

# --------------------------------------------------
# Test Cloudflare authentication
# --------------------------------------------------

echo "Testing Cloudflare API authentication..."

auth_response=$(curl -sS \
    --retry "$MAX_RETRIES" \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 60 \
    "${AUTH_HEADERS[@]}" \
    "${LISTS_URL}?type=DOMAIN")

if ! echo "$auth_response" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "$auth_response" | jq . 2>/dev/null || echo "$auth_response"
    error "Cloudflare API authentication failed."
fi

echo "Cloudflare authentication successful."

# --------------------------------------------------
# Get current Gateway lists
# --------------------------------------------------

echo "Getting Cloudflare Gateway lists..."

current_lists=$(curl -sS \
    --retry "$MAX_RETRIES" \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 120 \
    "${AUTH_HEADERS[@]}" \
    "${LISTS_URL}?type=DOMAIN")

if ! echo "$current_lists" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "$current_lists" | jq . 2>/dev/null || echo "$current_lists"
    error "Failed to get Cloudflare Gateway lists."
fi

# --------------------------------------------------
# Find our existing Block ads lists
# --------------------------------------------------

mapfile -t existing_list_ids < <(
    echo "$current_lists" |
    jq -r --arg PREFIX "$PREFIX" '
        .result[]
        | select(.name | startswith($PREFIX))
        | .id
    '
)

existing_count=${#existing_list_ids[@]}

echo "Existing Block ads lists: ${existing_count}"

# --------------------------------------------------
# Check list capacity
# --------------------------------------------------

current_other_count=$(
    echo "$current_lists" |
    jq -r --arg PREFIX "$PREFIX" '
        [
            .result[]
            | select((.name | startswith($PREFIX)) | not)
        ] | length
    '
)

echo "Other Cloudflare lists: ${current_other_count}"

available_slots=$((MAX_LISTS - current_other_count))

if (( total_lists > available_slots )); then
    error "Need ${total_lists} lists but only ${available_slots} list slots are available."
fi

# --------------------------------------------------
# Split domains into chunks
# --------------------------------------------------

echo "Splitting domains into chunks..."

rm -f "${CHUNK_PREFIX}"*

split -l "$MAX_LIST_SIZE" \
    "$DOMAIN_FILE" \
    "$CHUNK_PREFIX" \
    || error "Failed to split domain list."

mapfile -t chunked_lists < <(
    find . -maxdepth 1 -type f -name "${CHUNK_PREFIX}*" | sort
)

if (( ${#chunked_lists[@]} != total_lists )); then
    error "Expected ${total_lists} chunks but created ${#chunked_lists[@]}."
fi

echo "Created ${#chunked_lists[@]} chunks."

# --------------------------------------------------
# Used/excess list tracking
# --------------------------------------------------

used_list_ids=()
excess_list_ids=()

# --------------------------------------------------
# Update existing lists
# --------------------------------------------------

list_index=0

for list_id in "${existing_list_ids[@]}"; do

    if (( list_index >= total_lists )); then
        echo "Marking excess list ${list_id} for deletion..."
        excess_list_ids+=("$list_id")
        continue
    fi

    chunk_file="${chunked_lists[$list_index]}"

    echo ""
    echo "Updating list $((list_index + 1))/${total_lists}: ${list_id}"

    # Build list items.
    items_json=$(
        jq -R -s '
            split("\n")
            | map(select(length > 0) | {
                value: .
            })
        ' "$chunk_file"
    ) || error "Failed to create JSON for ${list_id}."

    # Get the existing list name so PUT does not accidentally rename it.
    list_details=$(curl -sS \
        --retry "$MAX_RETRIES" \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 120 \
        "${AUTH_HEADERS[@]}" \
        "${LISTS_URL}/${list_id}")

    if ! echo "$list_details" | jq -e '.success == true' >/dev/null 2>&1; then
        echo "$list_details" | jq . 2>/dev/null || echo "$list_details"
        error "Failed to get details for list ${list_id}."
    fi

    list_name=$(echo "$list_details" | jq -r '.result.name')

    if [[ -z "$list_name" || "$list_name" == "null" ]]; then
        error "Could not determine name for list ${list_id}."
    fi

    payload=$(
        jq -n \
            --arg name "$list_name" \
            --argjson items "$items_json" \
            '{
                name: $name,
                items: $items
            }'
    )

    # --------------------------------------------------
    # PUT replaces the existing list items.
    # --------------------------------------------------

    success=false

    for attempt in $(seq 1 "$MAX_RETRIES"); do

        echo "  PUT attempt ${attempt}/${MAX_RETRIES}..."

        response=$(curl -sS \
            -w $'\nHTTP_STATUS:%{http_code}' \
            --connect-timeout 15 \
            --max-time 180 \
            -X PUT \
            "${AUTH_HEADERS[@]}" \
            --data "$payload" \
            "${LISTS_URL}/${list_id}")

        http_status=$(echo "$response" | sed -n 's/^HTTP_STATUS://p')
        body=$(echo "$response" | sed '/^HTTP_STATUS:/d')

        if [[ "$http_status" == "200" ]] &&
           echo "$body" | jq -e '.success == true' >/dev/null 2>&1; then

            echo "  Updated successfully."
            success=true
            break
        fi

        echo "  Cloudflare returned HTTP ${http_status}."

        echo "$body" |
            jq -r '.errors[]?.message // empty' 2>/dev/null |
            sed 's/^/  Cloudflare: /'

        if [[ "$http_status" == "409" ]]; then
            echo "  Conflict detected. Waiting before retry..."
            sleep $((attempt * 5))
        elif [[ "$http_status" == "429" ]]; then
            echo "  Rate limited. Waiting before retry..."
            sleep $((attempt * 10))
        else
            echo "  Waiting before retry..."
            sleep 3
        fi
    done

    if [[ "$success" != true ]]; then
        error "Failed to update Cloudflare list ${list_id} after ${MAX_RETRIES} attempts."
    fi

    used_list_ids+=("$list_id")

    list_index=$((list_index + 1))

done

# --------------------------------------------------
# Create missing lists
# --------------------------------------------------

while (( list_index < total_lists )); do

    chunk_file="${chunked_lists[$list_index]}"

    formatted_counter=$(printf "%03d" "$((list_index + 1))")

    list_name="${PREFIX} - ${formatted_counter}"

    echo ""
    echo "Creating list ${list_name}..."

    items_json=$(
        jq -R -s '
            split("\n")
            | map(select(length > 0) | {
                value: .
            })
        ' "$chunk_file"
    ) || error "Failed to create JSON for ${list_name}."

    payload=$(
        jq -n \
            --arg name "$list_name" \
            --argjson items "$items_json" \
            '{
                name: $name,
                type: "DOMAIN",
                items: $items
            }'
    )

    success=false

    for attempt in $(seq 1 "$MAX_RETRIES"); do

        echo "  POST attempt ${attempt}/${MAX_RETRIES}..."

        response=$(curl -sS \
            -w $'\nHTTP_STATUS:%{http_code}' \
            --connect-timeout 15 \
            --max-time 180 \
            -X POST \
            "${AUTH_HEADERS[@]}" \
            --data "$payload" \
            "$LISTS_URL")

        http_status=$(echo "$response" | sed -n 's/^HTTP_STATUS://p')
        body=$(echo "$response" | sed '/^HTTP_STATUS:/d')

        if [[ "$http_status" == "200" ]] &&
           echo "$body" | jq -e '.success == true' >/dev/null 2>&1; then

            new_id=$(echo "$body" | jq -r '.result.id')

            if [[ -z "$new_id" || "$new_id" == "null" ]]; then
                error "Cloudflare created ${list_name}, but no list ID was returned."
            fi

            echo "  Created successfully: ${new_id}"

            used_list_ids+=("$new_id")
            success=true
            break
        fi

        echo "  Cloudflare returned HTTP ${http_status}."

        echo "$body" |
            jq -r '.errors[]?.message // empty' 2>/dev/null |
            sed 's/^/  Cloudflare: /'

        if [[ "$http_status" == "409" ]]; then
            echo "  Conflict detected. Waiting before retry..."
            sleep $((attempt * 5))
        elif [[ "$http_status" == "429" ]]; then
            echo "  Rate limited. Waiting before retry..."
            sleep $((attempt * 10))
        else
            sleep 3
        fi

    done

    if [[ "$success" != true ]]; then
        error "Failed to create Cloudflare list ${list_name}."
    fi

    list_index=$((list_index + 1))

done

# --------------------------------------------------
# Delete excess lists
# --------------------------------------------------

for list_id in "${excess_list_ids[@]}"; do

    echo ""
    echo "Deleting excess list ${list_id}..."

    response=$(curl -sS \
        -w $'\nHTTP_STATUS:%{http_code}' \
        --connect-timeout 15 \
        --max-time 120 \
        -X DELETE \
        "${AUTH_HEADERS[@]}" \
        "${LISTS_URL}/${list_id}")

    http_status=$(echo "$response" | sed -n 's/^HTTP_STATUS://p')
    body=$(echo "$response" | sed '/^HTTP_STATUS:/d')

    if [[ "$http_status" != "200" ]] &&
       [[ "$http_status" != "204" ]]; then

        echo "$body" | jq . 2>/dev/null || echo "$body"

        error "Failed to delete excess list ${list_id}."
    fi

    echo "  Deleted successfully."

done

# --------------------------------------------------
# Get current Gateway rules
# --------------------------------------------------

echo ""
echo "Getting Cloudflare Gateway policies..."

current_policies=$(curl -sS \
    --retry "$MAX_RETRIES" \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 120 \
    "${AUTH_HEADERS[@]}" \
    "$RULES_URL")

if ! echo "$current_policies" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "$current_policies" | jq . 2>/dev/null || echo "$current_policies"
    error "Failed to get Cloudflare Gateway policies."
fi

# --------------------------------------------------
# Find existing Block ads policy
# --------------------------------------------------

policy_id=$(
    echo "$current_policies" |
    jq -r --arg PREFIX "$PREFIX" '
        .result[]
        | select(.name == $PREFIX)
        | .id
    ' |
    head -n 1
)

# --------------------------------------------------
# Build policy expression
# --------------------------------------------------

echo "Building Block ads policy..."

if (( ${#used_list_ids[@]} == 0 )); then
    error "No Cloudflare lists are available for the policy."
fi

expressions=()

for list_id in "${used_list_ids[@]}"; do
    expressions+=(
        "{\"any\":{\"in\":{\"lhs\":{\"splat\":\"dns.domains\"},\"rhs\":\"\$${list_id}\"}}}"
    )
done

if (( ${#expressions[@]} == 1 )); then
    expression_json="${expressions[0]}"
else
    joined=$(IFS=','; echo "${expressions[*]}")
    expression_json="{\"or\":[${joined}]}"
fi

json_data=$(
    jq -n \
        --arg name "$PREFIX" \
        --argjson expression "$expression_json" \
        '{
            name: $name,
            conditions: [
                {
                    type: "traffic",
                    expression: $expression
                }
            ],
            action: "block",
            enabled: true,
            description: "",
            rule_settings: {
                block_page_enabled: false,
                block_reason: "",
                biso_admin_controls: {
                    dcp: false,
                    dcr: false,
                    dd: false,
                    dk: false,
                    dp: false,
                    du: false
                },
                add_headers: {},
                ip_categories: false,
                override_host: "",
                override_ips: null,
                l4override: null,
                check_session: null
            },
            filters: ["dns"]
        }'
) || error "Failed to build Gateway policy JSON."

# --------------------------------------------------
# Create/update policy
# --------------------------------------------------

if [[ -z "$policy_id" || "$policy_id" == "null" ]]; then

    echo "Creating Block ads policy..."

    response=$(curl -sS \
        -w $'\nHTTP_STATUS:%{http_code}' \
        --connect-timeout 15 \
        --max-time 120 \
        -X POST \
        "${AUTH_HEADERS[@]}" \
        --data "$json_data" \
        "$RULES_URL")

    http_status=$(echo "$response" | sed -n 's/^HTTP_STATUS://p')
    body=$(echo "$response" | sed '/^HTTP_STATUS:/d')

    if [[ "$http_status" != "200" ]] ||
       ! echo "$body" | jq -e '.success == true' >/dev/null 2>&1; then

        echo "$body" | jq . 2>/dev/null || echo "$body"

        error "Failed to create Block ads policy."
    fi

    echo "Block ads policy created."

else

    echo "Updating Block ads policy ${policy_id}..."

    response=$(curl -sS \
        -w $'\nHTTP_STATUS:%{http_code}' \
        --connect-timeout 15 \
        --max-time 120 \
        -X PUT \
        "${AUTH_HEADERS[@]}" \
        --data "$json_data" \
        "${RULES_URL}/${policy_id}")

    http_status=$(echo "$response" | sed -n 's/^HTTP_STATUS://p')
    body=$(echo "$response" | sed '/^HTTP_STATUS:/d')

    if [[ "$http_status" != "200" ]] ||
       ! echo "$body" | jq -e '.success == true' >/dev/null 2>&1; then

        echo "$body" | jq . 2>/dev/null || echo "$body"

        error "Failed to update Block ads policy."
    fi

    echo "Block ads policy updated."

fi

# --------------------------------------------------
# Clean up temporary chunks
# --------------------------------------------------

rm -f "${CHUNK_PREFIX}"*

# --------------------------------------------------
# Commit updated domain file
# --------------------------------------------------

echo ""
echo "Updating repository..."

git config user.email \
    "${GITHUB_ACTOR_ID:-github-actions[bot]}+${GITHUB_ACTOR:-github-actions[bot]}@users.noreply.github.com"

git config user.name \
    "${GITHUB_ACTOR:-github-actions[bot]}"

git add "$DOMAIN_FILE" || error "Failed to stage domain list."

if git diff --cached --quiet; then
    echo "No repository changes to commit."
else

    git commit \
        -m "Update domains list" \
        || error "Failed to commit the domains list."

    git push origin HEAD:main \
        || error "Failed to push the updated domains list."
fi

echo ""
echo "========================================"
echo "SUCCESS"
echo "========================================"
echo "Block ads update completed successfully."
echo "Domains: ${total_lines}"
echo "Cloudflare lists: ${#used_list_ids[@]}"
echo "========================================"
