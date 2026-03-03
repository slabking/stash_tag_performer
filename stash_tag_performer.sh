#!/usr/bin/env bash
set -u

INSTANCE="Stash"
ENDPOINT="${STASH_ENDPOINT:-http://192.168.1.100:9999/graphql}"

echo "Using Stash endpoint: $INSTANCE - $ENDPOINT" >&2

API_KEY="${STASH_API_KEY:-}"
AUTO_CREATE_MISSING_TAGS="${AUTO_CREATE_MISSING_TAGS:-0}"

graphql() {
    local payload="$1"
    if [ -n "$API_KEY" ]; then
        curl -s -X POST -H "Content-Type: application/json" -H "ApiKey: $API_KEY" -d "$payload" "$ENDPOINT"
    else
        curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$ENDPOINT"
    fi
}

map_rating_to_tag() {
    local rating100="$1"
    if (( rating100 >= 81 )); then
        echo "rating_5_stars"
    elif (( rating100 >= 61 )); then
        echo "rating_4_stars"
    elif (( rating100 >= 41 )); then
        echo "rating_3_stars"
    elif (( rating100 >= 21 )); then
        echo "rating_2_stars"
    elif (( rating100 >= 1 )); then
        echo "rating_1_star"
    else
        echo "rating_none"
    fi
}

# --- TAGS: fetch all pages and aggregate ---
PER_PAGE_TAGS=100
PAGE_TAGS=1
TAGS_LINES=()

while :; do
    TAGS_QUERY=$(cat <<-GRAPHQL
{"query":"{ findTags(filter: {page: $PAGE_TAGS, per_page: $PER_PAGE_TAGS}) { tags { id name } } }"}
GRAPHQL
)
    RES=$(graphql "$TAGS_QUERY")
    if ! echo "$RES" | jq . >/dev/null 2>&1; then
        echo "Failed to parse tags response as JSON (page $PAGE_TAGS). Raw response:" >&2
        echo "$RES" >&2
        exit 1
    fi

    # Extract compact tag objects (one-per-line). If none, break.
    PAGE_TAGS_RAW=$(echo "$RES" | jq -c '.data.findTags.tags[]?' || true)
    if [ -z "$PAGE_TAGS_RAW" ]; then
        break
    fi

    # Append each tag JSON object line to TAGS_LINES
    while read -r line; do
        [ -z "$line" ] && continue
        TAGS_LINES+=("$line")
    done <<< "$PAGE_TAGS_RAW"

    # If fewer than PER_PAGE_TAGS returned, we've reached the last page (optimization)
    COUNT_ON_PAGE=$(echo "$RES" | jq '.data.findTags.tags | length // 0')
    if [ "$COUNT_ON_PAGE" -lt "$PER_PAGE_TAGS" ]; then
        break
    fi

    PAGE_TAGS=$((PAGE_TAGS + 1))
done

# Build aggregated TAGS_JSON with all tag objects
if [ "${#TAGS_LINES[@]}" -eq 0 ]; then
    TAGS_JSON='{"data":{"findTags":{"tags":[]}}}'
else
    JOINED=$(printf '%s,' "${TAGS_LINES[@]}")
    JOINED="${JOINED%,}" # remove trailing comma
    TAGS_JSON="{\"data\":{\"findTags\":{\"tags\":[$JOINED]}}}"
fi

# Quick sanity: ensure TAGS_JSON is valid
if ! echo "$TAGS_JSON" | jq . >/dev/null 2>&1; then
    echo "Aggregated TAGS_JSON is invalid. Raw content:" >&2
    echo "$TAGS_JSON" >&2
    exit 1
fi

# rating tag names used by the script (edit these if you prefer other names)
RATING_TAG_NAMES=("rating_5_stars" "rating_4_stars" "rating_3_stars" "rating_2_stars" "rating_1_star" "rating_none")

# Build a list of rating tag IDs (plain array)
RATING_TAG_IDS=()
for tag_name in "${RATING_TAG_NAMES[@]}"; do
    tag_id=$(echo "$TAGS_JSON" | jq -r --arg name "$tag_name" '.data.findTags.tags[]? | select(.name == $name) | .id')
    if [ -n "$tag_id" ] && [ "$tag_id" != "null" ]; then
        RATING_TAG_IDS+=("$tag_id")
    fi
done

# Helper to get tag ID for a given name (exact then case-insensitive)
get_tag_id() {
    local tag_name="$1"
    tag_id=$(echo "$TAGS_JSON" | jq -r --arg name "$tag_name" '.data.findTags.tags[]? | select(.name == $name) | .id')
    if [ -n "$tag_id" ] && [ "$tag_id" != "null" ]; then
        echo "$tag_id"
        return 0
    fi
    name_lc=$(printf '%s' "$tag_name" | tr '[:upper:]' '[:lower:]')
    tag_id=$(echo "$TAGS_JSON" | jq -r --arg name_lc "$name_lc" '.data.findTags.tags[]? | select((.name|ascii_downcase) == $name_lc) | .id' 2>/dev/null || true)
    if [ -n "$tag_id" ] && [ "$tag_id" != "null" ]; then
        echo "$tag_id"
        return 0
    fi
    echo ""
    return 1
}

# Optionally create missing tags (unchanged behavior from previous script)
create_tag() {
    local tag_name="$1"
    PAYLOAD=$(jq -n --arg name "$tag_name" '{"query":"mutation { tagCreate(input: { name: \($name) }) { id name } }"}')
    RES=$(graphql "$PAYLOAD")
    echo "$RES"
}

# Detect missing rating tags
MISSING=()
for tag_name in "${RATING_TAG_NAMES[@]}"; do
    tid=$(get_tag_id "$tag_name")
    if [ -z "$tid" ]; then
        MISSING+=("$tag_name")
    fi
done

if [ "${#MISSING[@]}" -ne 0 ]; then
    echo "Missing rating tags: ${MISSING[*]}" >&2
    if [ "$AUTO_CREATE_MISSING_TAGS" = "1" ]; then
        echo "AUTO_CREATE_MISSING_TAGS=1 so attempting to create missing tags..." >&2
        for t in "${MISSING[@]}"; do
            echo "Creating tag '$t'..." >&2
            create_res=$(create_tag "$t")
            if echo "$create_res" | jq -e '.errors' >/dev/null 2>&1; then
                echo "Error creating tag '$t':" >&2
                echo "$create_res" | jq .errors >&2
            else
                echo "Create response for '$t':" >&2
                echo "$create_res" | jq . >&2 || echo "$create_res" >&2
            fi
        done
        # re-fetch aggregated tags (simple approach: re-run the tag fetch loop once)
        PER_PAGE_TAGS=100
        PAGE_TAGS=1
        TAGS_LINES=()
        while :; do
            TAGS_QUERY=$(cat <<-GRAPHQL
{"query":"{ findTags(filter: {page: $PAGE_TAGS, per_page: $PER_PAGE_TAGS}) { tags { id name } } }"}
GRAPHQL
)
            RES=$(graphql "$TAGS_QUERY")
            PAGE_TAGS_RAW=$(echo "$RES" | jq -c '.data.findTags.tags[]?' || true)
            if [ -z "$PAGE_TAGS_RAW" ]; then
                break
            fi
            while read -r line; do
                [ -z "$line" ] && continue
                TAGS_LINES+=("$line")
            done <<< "$PAGE_TAGS_RAW"
            COUNT_ON_PAGE=$(echo "$RES" | jq '.data.findTags.tags | length // 0')
            if [ "$COUNT_ON_PAGE" -lt "$PER_PAGE_TAGS" ]; then
                break
            fi
            PAGE_TAGS=$((PAGE_TAGS + 1))
        done
        if [ "${#TAGS_LINES[@]}" -eq 0 ]; then
            TAGS_JSON='{"data":{"findTags":{"tags":[]}}}'
        else
            JOINED=$(printf '%s,' "${TAGS_LINES[@]}")
            JOINED="${JOINED%,}"
            TAGS_JSON="{\"data\":{\"findTags\":{\"tags\":[$JOINED]}}}"
        fi
        # rebuild RATING_TAG_IDS
        RATING_TAG_IDS=()
        for tag_name in "${RATING_TAG_NAMES[@]}"; do
            tag_id=$(echo "$TAGS_JSON" | jq -r --arg name "$tag_name" '.data.findTags.tags[]? | select(.name == $name) | .id')
            if [ -n "$tag_id" ] && [ "$tag_id" != "null" ]; then
                RATING_TAG_IDS+=("$tag_id")
            fi
        done
    else
        echo "Auto-creation disabled. To auto-create set AUTO_CREATE_MISSING_TAGS=1" >&2
        echo "Available tags (id:name):" >&2
        echo "$TAGS_JSON" | jq -r '.data.findTags.tags[]? | .id + ":" + .name' >&2
        echo "Either create tags named exactly: ${RATING_TAG_NAMES[*]} or update RATING_TAG_NAMES in the script to match your tag names." >&2
    fi
fi

# --- PERFORMERS: pagination loop (unchanged logic) ---
PER_PAGE=100
PAGE=1

while :; do
    PERFORMERS_QUERY=$(cat <<-GRAPHQL
{"query":"{ findPerformers(filter: {page: $PAGE, per_page: $PER_PAGE}) { performers { id name rating100 tags { id name } } } }"}
GRAPHQL
)
    PERFORMERS_JSON=$(graphql "$PERFORMERS_QUERY")
    if ! echo "$PERFORMERS_JSON" | jq . >/dev/null 2>&1; then
        echo "Failed to parse performers response as JSON (page $PAGE). Raw response:" >&2
        echo "$PERFORMERS_JSON" >&2
        exit 1
    fi

    PERFORMERS_COUNT=$(echo "$PERFORMERS_JSON" | jq '.data.findPerformers.performers | length // 0')
    if [ "$PERFORMERS_COUNT" -eq 0 ]; then
        break
    fi

    echo "Processing page $PAGE (per_page=$PER_PAGE), performers returned: $PERFORMERS_COUNT" >&2

    echo "$PERFORMERS_JSON" | jq -c '.data.findPerformers.performers[]' | while read -r performer; do
        [ -z "$performer" ] && continue
        id=$(echo "$performer" | jq -r '.id')
        name=$(echo "$performer" | jq -r '.name')
        rating100=$(echo "$performer" | jq -r '.rating100 // 0')
        new_tag=$(map_rating_to_tag "$rating100")
        new_tag_id=$(get_tag_id "$new_tag")

        if [ -z "$new_tag_id" ] || [ "$new_tag_id" = "null" ]; then
            echo "Tag '$new_tag' not found in tag list. Skipping performer '$name'." >&2
            echo "Available tags (id:name) for debugging:" >&2
            echo "$TAGS_JSON" | jq -r '.data.findTags.tags[]? | .id + ":" + .name' >&2
            echo "Hint: Either create tags named exactly: ${RATING_TAG_NAMES[*]} or update RATING_TAG_NAMES in the script to match your tag names." >&2
            continue
        fi

        CURRENT_TAG_IDS=$(echo "$performer" | jq -r '.tags // [] | .[].id' || true)
        UPDATED_TAG_IDS=()
        for tag_id in $CURRENT_TAG_IDS; do
            skip_tag=false
            for rating_id in "${RATING_TAG_IDS[@]}"; do
                if [ "$tag_id" = "$rating_id" ]; then
                    skip_tag=true
                    break
                fi
            done
            if [ "$skip_tag" = false ]; then
                UPDATED_TAG_IDS+=("$tag_id")
            fi
        done

        UPDATED_TAG_IDS+=("$new_tag_id")
        IDS_ARRAY=$(printf '"%s",' "${UPDATED_TAG_IDS[@]}")
        IDS_ARRAY="${IDS_ARRAY%,}"
        JSON_PAYLOAD=$(jq -n --arg q "mutation { performerUpdate(input: { id: \"$id\", tag_ids: [${IDS_ARRAY}] }) { id } }" '{query: $q}')
        RESPONSE=$(graphql "$JSON_PAYLOAD")
        if echo "$RESPONSE" | jq -e '.data.performerUpdate.id' >/dev/null 2>&1; then
            echo "Performer '$name' now has tag '$new_tag'."
        else
            echo "Update failed for performer '$name' (id: $id). Server response:" >&2
            echo "$RESPONSE" | jq . >&2 || echo "$RESPONSE" >&2
        fi
    done

    PAGE=$((PAGE + 1))
done

echo "Done processing performers." >&2

exit
