#!/bin/bash

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

PREFIX="Block ads"

MAX_LIST_SIZE=1000
MAX_LISTS=100
MAX_RETRIES=10

DOMAINS_URL="https://small.oisd.nl/domainswild2"

CLOUDFLARE_API="https://api.cloudflare.com/client/v4"

DOMAINS_FILE="oisd_small_domainswild2.txt"


# ============================================================
# Error handling
# ============================================================

error() {
    echo ""
    echo "========================================"
    echo "ERROR"
    echo "========================================"
    echo "$1"
    echo "========================================"
    echo ""

    rm -f "${DOMAINS_FILE}."*
    exit 1
}


# ============================================================
# Check environment
# ============================================================

echo "========================================"
echo "Block Ads Update"
echo "========================================"

if [ -z "${API_TOKEN:-}" ]; then
    error "API_TOKEN is not set."
fi

if [ -z "${ACCOUNT_ID:-}" ]; then
    error "ACCOUNT_ID is not set."
fi

echo "Cloudflare account: ${ACCOUNT_ID}"
echo ""


# ============================================================
# Download latest OISD domains list
# ============================================================

echo "Downloading latest OISD domain list..."

if ! curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry "${MAX_RETRIES}" \
    --retry-all-errors \
    --connect-timeout 20 \
    --max-time 120 \
    "${DOMAINS_URL}" \
    | grep -vE '^[[:space:]]*(#|$)' \
    > "${DOMAINS_FILE}"; then

    error "Failed to download the OISD domains list."
fi


# ============================================================
# Check downloaded file
# ============================================================

if [ ! -s "${DOMAINS_FILE}" ]; then
    error "The downloaded domains list is empty."
fi

total_lines=$(wc -l < "${DOMAINS_FILE}")

echo "Downloaded ${total_lines} domains."

if [ "${total_lines}" -gt $((MAX_LIST_SIZE * MAX_LISTS)) ]; then
    error "The domains list contains ${total_lines} lines, which exceeds the maximum allowed."
fi


# ============================================================
# Check whether domains changed
# ============================================================

if git diff --quiet -- "${DOMAINS_FILE}"; then
    echo ""
    echo "The domains list has not changed."
    echo "Nothing needs to be updated."
    echo ""
    exit 0
fi

echo "The domains list has changed."
echo ""


# ============================================================
# Calculate number of Cloudflare lists required
# ============================================================

total_lists=$((total_lines / MAX_LIST_SIZE))

if [ $((total_lines % MAX_LIST_SIZE)) -ne 0 ]; then
    total_lists=$((total_lists + 1))
fi

echo "Cloudflare lists required: ${total_lists}"


# ============================================================
# Cloudflare API helper
# ============================================================

cloudflare_get() {
    local endpoint="$1"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry "${MAX_RETRIES}" \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 120 \
        -X GET \
        "${CLOUDFLARE_API}${endpoint}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json"
}


cloudflare_post() {
    local endpoint="$1"
    local payload="$2"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry "${MAX_RETRIES}" \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 120 \
        -X POST \
        "${CLOUDFLARE_API}${endpoint}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "${payload}"
}


cloudflare_patch() {
    local endpoint="$1"
    local payload="$2"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry "${MAX_RETRIES}" \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 120 \
        -X PATCH \
        "${CLOUDFLARE_API}${endpoint}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "${payload}"
}


cloudflare_put() {
    local endpoint="$1"
    local payload="$2"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry "${MAX_RETRIES}" \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 120 \
        -X PUT \
        "${CLOUDFLARE_API}${endpoint}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "${payload}"
}


cloudflare_delete() {
    local endpoint="$1"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry "${MAX_RETRIES}" \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 120 \
        -X DELETE \
        "${CLOUDFLARE_API}${endpoint}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json"
}


# ============================================================
# Test Cloudflare authentication
# ============================================================

echo ""
echo "Testing Cloudflare API authentication..."

current_lists=$(cloudflare_get \
    "/accounts/${ACCOUNT_ID}/gateway/lists") || \
    error "Failed to get Cloudflare Gateway lists. Check API_TOKEN, ACCOUNT_ID and token permissions."

if ! echo "${current_lists}" | jq -e '.success == true' >/dev/null; then
    echo "${current_lists}" | jq .
    error "Cloudflare returned an API error while getting Gateway lists."
fi

echo "Cloudflare authentication successful."


# ============================================================
# Get current policies
# ============================================================

echo ""
echo "Getting Cloudflare Gateway policies..."

current_policies=$(cloudflare_get \
    "/accounts/${ACCOUNT_ID}/gateway/rules") || \
    error "Failed to get Cloudflare Gateway policies."

if ! echo "${current_policies}" | jq -e '.success == true' >/dev/null; then
    echo "${current_policies}" | jq .
    error "Cloudflare returned an API error while getting Gateway policies."
fi


# ============================================================
# Count existing Block ads lists
# ============================================================

current_lists_count=$(
    echo "${current_lists}" |
    jq -r --arg PREFIX "${PREFIX}" '
        [.result[]? |
        select(.name | contains($PREFIX))] |
        length
    '
) || error "Failed to count existing Block ads lists."


current_lists_count_without_prefix=$(
    echo "${current_lists}" |
    jq -r --arg PREFIX "${PREFIX}" '
        [.result[]? |
        select((.name | contains($PREFIX)) | not)] |
        length
    '
) || error "Failed to count non-Block ads lists."


echo "Existing Block ads lists: ${current_lists_count}"
echo "Other Cloudflare lists: ${current_lists_count_without_prefix}"


# ============================================================
# Check list limit
# ============================================================

available_slots=$((MAX_LISTS - current_lists_count_without_prefix))

if [ "${total_lists}" -gt "${available_slots}" ]; then
    error "Need ${total_lists} Block ads lists, but only ${available_slots} list slots are available."
fi


# ============================================================
# Split domain list
# ============================================================

echo ""
echo "Splitting domains into chunks..."

rm -f "${DOMAINS_FILE}."*

split \
    -l "${MAX_LIST_SIZE}" \
    "${DOMAINS_FILE}" \
    "${DOMAINS_FILE}." || \
    error "Failed to split the domains list."


chunked_lists=()

for file in "${DOMAINS_FILE}."*; do
    if [ -f "${file}" ]; then
        chunked_lists+=("${file}")
    fi
done


if [ "${#chunked_lists[@]}" -eq 0 ]; then
    error "No domain chunks were created."
fi

echo "Created ${#chunked_lists[@]} chunks."


# ============================================================
# Arrays
# ============================================================

used_list_ids=()
excess_list_ids=()

list_counter=1


# ============================================================
# Update existing lists
# ============================================================

if [ "${current_lists_count}" -gt 0 ]; then

    existing_ids=$(
        echo "${current_lists}" |
        jq -r --arg PREFIX "${PREFIX}" '
            .result[]? |
            select(.name | contains($PREFIX)) |
            .id
        '
    ) || error "Failed to get existing Block ads list IDs."


    while IFS= read -r list_id; do

        [ -z "${list_id}" ] && continue

        if [ "${#chunked_lists[@]}" -eq 0 ]; then
            echo "Marking list ${list_id} for deletion..."
            excess_list_ids+=("${list_id}")
            continue
        fi

        echo ""
        echo "Updating list ${list_id}..."

        list_items=$(
            cloudflare_get \
            "/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=${MAX_LIST_SIZE}"
        ) || error "Failed to get list ${list_id} contents."


        if ! echo "${list_items}" | jq -e '.success == true' >/dev/null; then
            echo "${list_items}" | jq .
            error "Cloudflare returned an error while reading list ${list_id}."
        fi


        list_items_values=$(
            echo "${list_items}" |
            jq -c '
                [.result[]? |
                .value |
                select(. != null)]
            '
        ) || error "Failed to read existing list items."


        list_items_array=$(
            jq -R -s '
                split("\n") |
                map(
                    select(length > 0) |
                    {
                        "value": .
                    }
                )
            ' "${chunked_lists[0]}"
        ) || error "Failed to create new list items."


        payload=$(
            jq -n \
                --argjson append_items "${list_items_array}" \
                --argjson remove_items "${list_items_values}" \
                '{
                    "append": $append_items,
                    "remove": $remove_items
                }'
        ) || error "Failed to create Cloudflare update payload."


        list=$(
            cloudflare_patch \
                "/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
                "${payload}"
        ) || error "Failed to update Cloudflare list ${list_id}."


        if ! echo "${list}" | jq -e '.success == true' >/dev/null; then
            echo "${list}" | jq .
            error "Cloudflare rejected the update for list ${list_id}."
        fi


        used_list_ids+=("${list_id}")

        rm -f "${chunked_lists[0]}"

        chunked_lists=(
            "${chunked_lists[@]:1}"
        )

        list_counter=$((list_counter + 1))

    done <<< "${existing_ids}"

fi


# ============================================================
# Create new lists
# ============================================================

for file in "${chunked_lists[@]}"; do

    echo ""
    echo "Creating Cloudflare list..."

    formatted_counter=$(printf "%03d" "${list_counter}")

    list_name="${PREFIX} - ${formatted_counter}"


    items=$(
        jq -R -s '
            split("\n") |
            map(
                select(length > 0) |
                {
                    "value": .
                }
            )
        ' "${file}"
    ) || error "Failed to create items for ${list_name}."


    payload=$(
        jq -n \
            --arg name "${list_name}" \
            --argjson items "${items}" \
            '{
                "name": $name,
                "type": "DOMAIN",
                "items": $items
            }'
    ) || error "Failed to create payload for ${list_name}."


    list=$(
        cloudflare_post \
            "/accounts/${ACCOUNT_ID}/gateway/lists" \
            "${payload}"
    ) || error "Failed to create Cloudflare list ${list_name}."


    if ! echo "${list}" | jq -e '.success == true' >/dev/null; then
        echo "${list}" | jq .
        error "Cloudflare rejected creation of ${list_name}."
    fi


    list_id=$(
        echo "${list}" |
        jq -r '.result.id // empty'
    )


    if [ -z "${list_id}" ]; then
        echo "${list}" | jq .
        error "Cloudflare did not return a list ID for ${list_name}."
    fi


    echo "Created ${list_name}: ${list_id}"

    used_list_ids+=("${list_id}")

    rm -f "${file}"

    list_counter=$((list_counter + 1))

done


# ============================================================
# Verify list IDs
# ============================================================

if [ "${#used_list_ids[@]}" -eq 0 ]; then
    error "No Cloudflare list IDs are available for the policy."
fi

echo ""
echo "Lists being used by policy: ${#used_list_ids[@]}"


# ============================================================
# Find existing Block ads policy
# ============================================================

policy_id=$(
    echo "${current_policies}" |
    jq -r --arg PREFIX "${PREFIX}" '
        .result[]? |
        select(.name == $PREFIX) |
        .id
    ' |
    head -n 1
) || error "Failed to find existing Block ads policy."


# ============================================================
# Build policy expression
# ============================================================

if [ "${#used_list_ids[@]}" -eq 1 ]; then

    list_id="${used_list_ids[0]}"

    expression=$(jq -n \
        --arg list_id "${list_id}" \
        '{
            "any": {
                "in": {
                    "lhs": {
                        "splat": "dns.domains"
                    },
                    "rhs": ("$" + $list_id)
                }
            }
        }'
    ) || error "Failed to create policy expression."

else

    expression_items=()

    for list_id in "${used_list_ids[@]}"; do

        expression_items+=(
            "$(
                jq -n \
                    --arg list_id "${list_id}" \
                    '{
                        "any": {
                            "in": {
                                "lhs": {
                                    "splat": "dns.domains"
                                },
                                "rhs": ("$" + $list_id)
                            }
                        }
                    }'
            )"
        )

    done


    conditions_json=$(
        printf '%s\n' "${expression_items[@]}" |
        jq -s .
    ) || error "Failed to create policy conditions."


    expression=$(
        jq -n \
            --argjson conditions "${conditions_json}" \
            '{
                "or": $conditions
            }'
    ) || error "Failed to create policy expression."

fi


# ============================================================
# Build complete policy JSON
# ============================================================

json_data=$(
    jq -n \
        --arg name "${PREFIX}" \
        --argjson expression "${expression}" \
        '{
            "name": $name,
            "conditions": [
                {
                    "type": "traffic",
                    "expression": $expression
                }
            ],
            "action": "block",
            "enabled": true,
            "description": "",
            "rule_settings": {
                "block_page_enabled": false,
                "block_reason": "",
                "biso_admin_controls": {
                    "dcp": false,
                    "dcr": false,
                    "dd": false,
                    "dk": false,
                    "dp": false,
                    "du": false
                },
                "add_headers": {},
                "ip_categories": false,
                "override_host": "",
                "override_ips": null,
                "l4override": null,
                "check_session": null
            },
            "filters": [
                "dns"
            ]
        }'
) || error "Failed to create policy JSON."


echo ""
echo "Policy JSON generated successfully."


# ============================================================
# Create or update policy
# ============================================================

if [ -z "${policy_id}" ] || [ "${policy_id}" = "null" ]; then

    echo ""
    echo "Creating Block ads policy..."

    policy_response=$(
        cloudflare_post \
            "/accounts/${ACCOUNT_ID}/gateway/rules" \
            "${json_data}"
    ) || error "Failed to create Block ads policy."


    if ! echo "${policy_response}" | jq -e '.success == true' >/dev/null; then
        echo "${policy_response}" | jq .
        error "Cloudflare rejected the Block ads policy."
    fi

    echo "Block ads policy created."

else

    echo ""
    echo "Updating Block ads policy ${policy_id}..."

    policy_response=$(
        cloudflare_put \
            "/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
            "${json_data}"
    ) || error "Failed to update Block ads policy."


    if ! echo "${policy_response}" | jq -e '.success == true' >/dev/null; then
        echo "${policy_response}" | jq .
        error "Cloudflare rejected the Block ads policy update."
    fi

    echo "Block ads policy updated."

fi


# ============================================================
# Delete excess lists
# ============================================================

for list_id in "${excess_list_ids[@]}"; do

    echo ""
    echo "Deleting excess list ${list_id}..."

    delete_response=$(
        cloudflare_delete \
            "/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}"
    ) || error "Failed to delete list ${list_id}."


    if ! echo "${delete_response}" | jq -e '.success == true' >/dev/null 2>&1; then

        # Some DELETE responses may have an empty body.
        if [ -n "${delete_response}" ]; then
            echo "${delete_response}" | jq .
            error "Cloudflare rejected deletion of list ${list_id}."
        fi

    fi

done


# ============================================================
# Commit updated domains file
# ============================================================

echo ""
echo "Preparing Git commit..."

git config user.email \
    "${GITHUB_ACTOR_ID}+${GITHUB_ACTOR}@users.noreply.github.com"

git config user.name \
    "${GITHUB_ACTOR}"


git add "${DOMAINS_FILE}" || \
    error "Failed to add ${DOMAINS_FILE} to Git."


# Check whether there is actually something to commit.

if git diff --cached --quiet; then

    echo "No Git changes to commit."

else

    git commit \
        -m "Update domains list" || \
        error "Failed to commit the domains list."


    echo "Pushing updated domains list..."

    git push origin main || \
        error "Failed to push the domains list to main."

fi


# ============================================================
# Cleanup
# ============================================================

rm -f "${DOMAINS_FILE}."*


echo ""
echo "========================================"
echo "SUCCESS"
echo "========================================"
echo "Block ads list update completed."
echo "Domains: ${total_lines}"
echo "Cloudflare lists: ${#used_list_ids[@]}"
echo "========================================"
