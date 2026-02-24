#!/bin/bash

# Radarr DV + HDR Tagging Script
# Runs from INSIDE the Radarr container
#
# Key differences from tag_dv_hdr.sh:
# - Uses localhost API URL instead of external IP
# - No path translation (uses container paths directly)
# - Log file saved in /config/scripts/logs/
# - Requires dovi_tool and ffmpeg installed in container

# ========== CONFIGURATION ==========
# Enable/disable tag categories (true/false)
ENABLE_HDR_FORMATS_TAGS=true    # SDR, PQ, HDR10, HDR10+, DV tags
ENABLE_NO_DV_TAGS=false         # No-DV tag
ENABLE_PROFILE_TAGS=true        # MEL, FEL tags
ENABLE_PROFILE8_TAGS=false      # DVProfile8 tags
ENABLE_CM_TAGS=true             # CM2, CM4 tags

RADARR_URL="http://radarr:7878/api/v3"
RADARR_API_KEY="xxxxx"
LOG_FILE="/config/scripts/logs/dv-hdr_tagarr.log"

# Path translation (not needed inside container)
# CONTAINER_PATH="/data/media"
# HOST_PATH="/mnt/user/data/media"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"
}

translate_path() {
    # Inside container - no translation needed
    echo "$1"
}

get_tag_id() {
    curl -s "${RADARR_URL}/tag?apikey=${RADARR_API_KEY}" | jq -r ".[] | select(.label == \"$1\") | .id"
}

create_tag() {
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"label\": \"$1\"}" \
        "${RADARR_URL}/tag?apikey=${RADARR_API_KEY}" | jq -r ".id"
}

ensure_tag() {
    local tag_id=$(get_tag_id "$1")
    if [ -z "$tag_id" ]; then
        tag_id=$(create_tag "$1")
    fi
    echo "$tag_id"
}

has_tag() {
    local movie_id=$1
    local tag_id=$2
    curl -s "${RADARR_URL}/movie/${movie_id}?apikey=${RADARR_API_KEY}" | \
        jq -e ".tags | index(${tag_id})" >/dev/null 2>&1
}

add_tag() {
    local movie_id=$1
    local tag_name=$2

    # Check if tag category is enabled
    if ! is_tag_enabled "$tag_name"; then
        return 0
    fi

    local tag_id=$(ensure_tag "$tag_name")

    if ! has_tag "$movie_id" "$tag_id"; then
        log "INFO" "  Adding tag: $tag_name"
        curl -s -X PUT -H "Content-Type: application/json" \
            -d "{\"movieIds\": [${movie_id}], \"tags\": [${tag_id}], \"applyTags\": \"add\"}" \
            "${RADARR_URL}/movie/editor?apikey=${RADARR_API_KEY}" >/dev/null
    fi
}

remove_tag() {
    local movie_id=$1
    local tag_name=$2

    # Only remove tags if their category is enabled (for conflict resolution)
    if ! is_tag_enabled "$tag_name"; then
        return 0
    fi

    local tag_id=$(get_tag_id "$tag_name")

    if [ -n "$tag_id" ] && has_tag "$movie_id" "$tag_id"; then
        log "INFO" "  Removing tag: $tag_name"
        curl -s -X PUT -H "Content-Type: application/json" \
            -d "{\"movieIds\": [${movie_id}], \"tags\": [${tag_id}], \"applyTags\": \"remove\"}" \
            "${RADARR_URL}/movie/editor?apikey=${RADARR_API_KEY}" >/dev/null
    fi
}

clean_disabled_categories() {
    local movie_id=$1

    # Clean HDR Format Tags if disabled
    if [ "$ENABLE_HDR_FORMATS_TAGS" != "true" ]; then
        for tag in "sdr" "hdr10" "hdr10plus" "pq" "dv"; do
            force_remove_tag "$movie_id" "$tag"
        done
    fi

    # Clean No-DV Tags if disabled
    if [ "$ENABLE_NO_DV_TAGS" != "true" ]; then
        force_remove_tag "$movie_id" "no-dv"
    fi

    # Clean Profile Tags if disabled
    if [ "$ENABLE_PROFILE_TAGS" != "true" ]; then
        for tag in "mel" "fel"; do
            force_remove_tag "$movie_id" "$tag"
        done
    fi

    # Clean Profile 8 Tags if disabled
    if [ "$ENABLE_PROFILE8_TAGS" != "true" ]; then
        force_remove_tag "$movie_id" "dvprofile8"
    fi

    # Clean CM Tags if disabled
    if [ "$ENABLE_CM_TAGS" != "true" ]; then
        for tag in "cm2" "cm4"; do
            force_remove_tag "$movie_id" "$tag"
        done
    fi
}

force_remove_tag() {
    local movie_id=$1
    local tag_name=$2

    local tag_id=$(get_tag_id "$tag_name")

    if [ -n "$tag_id" ] && has_tag "$movie_id" "$tag_id"; then
        log "INFO" "  Cleaning disabled tag: $tag_name"
        curl -s -X PUT -H "Content-Type: application/json" \
            -d "{\"movieIds\": [${movie_id}], \"tags\": [${tag_id}], \"applyTags\": \"remove\"}" \
            "${RADARR_URL}/movie/editor?apikey=${RADARR_API_KEY}" >/dev/null
    fi
}

is_tag_enabled() {
    local tag_name=$1

    case "$tag_name" in
        # HDR Format Tags (includes DV)
        "sdr"|"hdr"|"hdr10"|"hdr10plus"|"pq"|"dv")
            [ "$ENABLE_HDR_FORMATS_TAGS" = "true" ]
            ;;
        # No-DV Tags
        "no-dv")
            [ "$ENABLE_NO_DV_TAGS" = "true" ]
            ;;
        # Profile Tags (MEL, FEL only)
        "mel"|"fel")
            [ "$ENABLE_PROFILE_TAGS" = "true" ]
            ;;
        # Profile 8 Tags
        "dvprofile8")
            [ "$ENABLE_PROFILE8_TAGS" = "true" ]
            ;;
        # CM Tags
        "cm2"|"cm4")
            [ "$ENABLE_CM_TAGS" = "true" ]
            ;;
        *)
            # Unknown tag - default to enabled
            true
            ;;
    esac
}

extract_rpu() {
    local file="$1"
    [ ! -f "$file" ] && return 1

    local temp_rpu=$(mktemp)

    ffmpeg -loglevel error -i "$file" -c:v copy -vbsf hevc_mp4toannexb -f hevc -frames:v 100 - 2>/dev/null | \
        dovi_tool extract-rpu - -o "$temp_rpu" >/dev/null 2>&1 || {
        rm -f "$temp_rpu"
        return 1
    }

    local summary=$(dovi_tool info -i "$temp_rpu" --summary 2>/dev/null)
    rm -f "$temp_rpu"

    [ -z "$summary" ] && return 1
    echo "$summary"
}

process_movie() {
    local movie_id=$1

    log "INFO" "Processing movie ID: $movie_id"

    # First, clean up any tags from disabled categories
    clean_disabled_categories "$movie_id"

    # Get movie info from API
    local movie_json=$(curl -s "${RADARR_URL}/movie/${movie_id}?apikey=${RADARR_API_KEY}")

    # Check if movie has file
    local has_file=$(echo "$movie_json" | jq -r '.hasFile')
    if [ "$has_file" != "true" ]; then
        log "WARN" "  No file for movie $movie_id"
        return
    fi

    local file_path=$(echo "$movie_json" | jq -r '.movieFile.path')
    # Inside container - use path directly (no translation needed)
    local container_file="$file_path"
    local hdr_type=$(echo "$movie_json" | jq -r '.movieFile.mediaInfo.videoDynamicRangeType // empty')

    log "INFO" "  File: $(basename "$container_file")"
    log "INFO" "  HDR Type from API: ${hdr_type:-SDR}"

    # Determinar si el contenido tiene DV según la API
    local has_dv_in_api=false
    if echo "$hdr_type" | grep -qiE "DV|Dolby"; then
        has_dv_in_api=true
    fi

    # Process HDR tags first
    if [ -z "$hdr_type" ]; then
        log "INFO" "  → SDR"
        remove_tag "$movie_id" "hdr10"
        remove_tag "$movie_id" "hdr10plus"
        remove_tag "$movie_id" "pq"
        add_tag "$movie_id" "sdr"
    elif echo "$hdr_type" | grep -qiE "HDR10Plus|HDR10\+"; then
        log "INFO" "  → HDR10+"
        remove_tag "$movie_id" "hdr10"
        remove_tag "$movie_id" "sdr"
        remove_tag "$movie_id" "pq"
        add_tag "$movie_id" "hdr10plus"
    elif echo "$hdr_type" | grep -qiE "(^HDR10$|HDR10[^P+]| HDR10)"; then
        log "INFO" "  → HDR10"
        remove_tag "$movie_id" "hdr10plus"
        remove_tag "$movie_id" "sdr"
        remove_tag "$movie_id" "pq"
        add_tag "$movie_id" "hdr10"
    elif echo "$hdr_type" | grep -qiE "^HDR|PQ"; then
        log "INFO" "  → PQ"
        remove_tag "$movie_id" "hdr10"
        remove_tag "$movie_id" "hdr10plus"
        remove_tag "$movie_id" "sdr"
        add_tag "$movie_id" "pq"
    else
        log "INFO" "  → SDR (unknown HDR type: $hdr_type)"
        remove_tag "$movie_id" "hdr10"
        remove_tag "$movie_id" "hdr10plus"
        remove_tag "$movie_id" "pq"
        add_tag "$movie_id" "sdr"
    fi

    # Process DV only if API indicates DV is present
    if [ "$has_dv_in_api" = true ]; then
        log "INFO" "  API indicates DV - analyzing metadata..."
        local dv_summary=$(extract_rpu "$container_file")

        if [ -n "$dv_summary" ]; then
            # DOLBY VISION DETECTED
            log "INFO" "  → DV confirmed"
            remove_tag "$movie_id" "no-dv"
            add_tag "$movie_id" "dv"

            # Debug: mostrar salida completa de dovi_tool
            log "INFO" "  DV SUMMARY COMPLETO:"
            echo "$dv_summary" | while read line; do
                [ -n "$line" ] && log "INFO" "    $line"
            done

            # Check Profile and Enhancement Layer - lógica corregida
            if echo "$dv_summary" | grep -qE "Profile: 7"; then
                if echo "$dv_summary" | grep -qiE "FEL"; then
                    log "INFO" "  → Profile 7 (FEL)"
                    remove_tag "$movie_id" "mel"
                    remove_tag "$movie_id" "dvprofile8"
                    add_tag "$movie_id" "fel"
                else
                    log "INFO" "  → Profile 7 (MEL)"
                    remove_tag "$movie_id" "fel"
                    remove_tag "$movie_id" "dvprofile8"
                    add_tag "$movie_id" "mel"
                fi
            elif echo "$dv_summary" | grep -qE "Profile: 8"; then
                log "INFO" "  → Profile 8 (Base Layer)"
                remove_tag "$movie_id" "fel"
                remove_tag "$movie_id" "mel"
                add_tag "$movie_id" "dvprofile8"
            else
                log "INFO" "  → Unknown Profile"
                remove_tag "$movie_id" "fel"
                remove_tag "$movie_id" "mel"
                remove_tag "$movie_id" "dvprofile8"
            fi

            # Check CM version
            if echo "$dv_summary" | grep -qiE "CM v4\.0"; then
                log "INFO" "  → CM 4.0"
                remove_tag "$movie_id" "cm2"
                add_tag "$movie_id" "cm4"
            elif echo "$dv_summary" | grep -qiE "CM v[0-9]"; then
                local cm_version=$(echo "$dv_summary" | grep -oiE "CM v[0-9]\.[0-9]+" | head -1)
                log "INFO" "  → ${cm_version}"
                remove_tag "$movie_id" "cm4"
                add_tag "$movie_id" "cm2"
            else
                log "INFO" "  → CM 2.x (default)"
                remove_tag "$movie_id" "cm4"
                add_tag "$movie_id" "cm2"
            fi
        else
            log "WARN" "  → API says DV but extraction failed"
            remove_tag "$movie_id" "dv"
            remove_tag "$movie_id" "fel"
            remove_tag "$movie_id" "mel"
            remove_tag "$movie_id" "cm2"
            remove_tag "$movie_id" "cm4"
            add_tag "$movie_id" "no-dv"
        fi
    else
        # NO DOLBY VISION in API
        log "INFO" "  → No DV in API"
        remove_tag "$movie_id" "dv"
        remove_tag "$movie_id" "fel"
        remove_tag "$movie_id" "mel"
        remove_tag "$movie_id" "cm2"
        remove_tag "$movie_id" "cm4"
        add_tag "$movie_id" "no-dv"
    fi

    log "INFO" "  ✓ Done"
    sleep 0.2
}

# Main
log "INFO" "==================== Starting Tagging Script (Inside Container) ===================="
log "INFO" "Tag Categories Enabled:"
log "INFO" "  HDR Format Tags (SDR/HDR/HDR10/HDR10+/PQ/DV): $ENABLE_HDR_FORMATS_TAGS"
log "INFO" "  No-DV Tags: $ENABLE_NO_DV_TAGS"
log "INFO" "  Profile Tags (MEL/FEL): $ENABLE_PROFILE_TAGS"
log "INFO" "  Profile 8 Tags (DVProfile8): $ENABLE_PROFILE8_TAGS"
log "INFO" "  CM Tags (CM2/CM4): $ENABLE_CM_TAGS"
log "INFO" "Fetching movie IDs from Radarr..."

# Get list of movie IDs with files
movie_ids=$(curl -s "${RADARR_URL}/movie?apikey=${RADARR_API_KEY}" | \
    jq -r '.[] | select(.hasFile == true) | .id')

total=$(echo "$movie_ids" | wc -l)
log "INFO" "Found $total movies with files"

counter=0
for movie_id in $movie_ids; do
    counter=$((counter + 1))
    log "INFO" "[$counter/$total] =============================="
    process_movie "$movie_id"
done

log "INFO" "==================== Completed! ===================="
