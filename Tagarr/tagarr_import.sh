#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Tagarr Import — Event-Driven Radarr Tagger with Discovery
# Version: 1.0.0
#
# Radarr Connect handler that tags individual movies on import, upgrade, or
# file delete events. Tags are based on release group, quality source
# (MA/Play WEB-DL), and lossless audio codec (TrueHD, TrueHD Atmos, DTS-X,
# DTS-HD MA). Optionally syncs tags to a secondary Radarr instance.
#
# Features:
#   TAGGING    — Match movies by release group + quality + audio filters
#   SYNC       — Mirror tags to a secondary Radarr instance (optional)
#   DISCOVERY  — Auto-detect new release groups that pass all filters but
#                aren't in the config yet. Writes them as commented entries
#                for manual review and activation. (optional)
#   CLEANUP    — Remove managed tags when movie file is deleted
#   DEBUG      — Log every filter decision per event (optional)
#   SMART      — Only send Discord notifications when something happens
#                (tagged or discovered). Silent otherwise.
#
# Setup:
#   Radarr > Settings > Connect > Custom Script
#   Path: /scripts/tagarr_import.sh
#   Events: On Download, On Upgrade, On File Delete
#
# Based on auto_tag_import.sh v3.4.1. Configuration: tagarr_import.conf
#
# Author: prophetSe7en
#
# WARNING: Runs automatically on every import/upgrade/delete event.
# Test with a single movie before enabling as a Radarr Connect handler.
# -----------------------------------------------------------------------------

SCRIPT_VERSION="1.0.0"

########################################
# CONFIG LOADING
########################################

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_NAME="$(basename "$0" .sh)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi

# Constructed API URLs
PRIMARY_RADARR_API_URL="${PRIMARY_RADARR_URL}/api/v3"
SECONDARY_RADARR_API_URL="${SECONDARY_RADARR_URL}/api/v3"

########################################
# DISCOVERY SETUP
########################################

# Build set of ALL known release groups from config (active + commented)
declare -A known_release_groups
known_release_groups[_]=1; unset "known_release_groups[_]"
while IFS= read -r line; do
    if [[ "$line" =~ \"([^:\"]+):[^:\"]+:[^:\"]+:[^:\"]+\" ]]; then
        known_release_groups["${BASH_REMATCH[1],,}"]=1
    fi
done < "$CONFIG_FILE"

########################################
# EVENT VARIABLES FROM RADARR
########################################

EVENT_TYPE="${radarr_eventtype:-Test}"
MOVIE_ID="${radarr_movie_id:-0}"
MOVIE_FILE_PATH="${radarr_moviefile_path:-}"
MOVIE_FILE_RELATIVE="${radarr_moviefile_relativepath:-}"
MOVIE_FILE_SCENE="${radarr_moviefile_scenename:-}"

################################################################################
# LOGGING AND LOG ROTATION
################################################################################

log() {
    if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    fi
}

# Ensure log directory exists
if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi

if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 2097152 ]; then
        [ -f "${LOG_FILE}.old" ] && rm "${LOG_FILE}.old"
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log "INFO" "Log rotated - previous log saved as ${LOG_FILE}.old"
    fi
fi

################################################################################
# HANDLE MOVIE FILE DELETE EVENT
################################################################################

if [ "$EVENT_TYPE" = "MovieFileDelete" ] || [ "$EVENT_TYPE" = "MovieFileDeleteForUpgrade" ]; then
    log "INFO" "============================================"
    log "INFO" "Tagarr Import v${SCRIPT_VERSION}"
    log "INFO" "Event: $EVENT_TYPE"
    log "INFO" "============================================"

    log "INFO" "Movie file deleted - removing all managed tags"

    # Get movie details
    movie_json=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")

    if [ -z "$movie_json" ]; then
        log "ERROR" "Failed to fetch movie details from Radarr"
        exit 1
    fi

    MOVIE_TITLE=$(echo "$movie_json" | jq -r '.title')
    MOVIE_YEAR=$(echo "$movie_json" | jq -r '.year')
    MOVIE_TMDB_ID=$(echo "$movie_json" | jq -r '.tmdbId')
    MOVIE_CURRENT_TAGS=$(echo "$movie_json" | jq -r '.tags')

    log "INFO" "Movie: $MOVIE_TITLE ($MOVIE_YEAR)"

    # Get all managed tag IDs
    declare -a managed_tag_ids=()

    for tag_config in "${RELEASE_GROUPS[@]}"; do
        TAG_NAME=$(echo "$tag_config" | cut -d: -f2)

        # Get tag ID in primary
        primary_tag_id=$(curl -s "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" | \
            jq -r ".[] | select(.label == \"${TAG_NAME}\") | .id")

        if [ -n "$primary_tag_id" ]; then
            managed_tag_ids+=("$primary_tag_id")
        fi
    done

    # Check if movie has any managed tags
    has_managed_tags=false
    for tag_id in "${managed_tag_ids[@]}"; do
        if echo "$MOVIE_CURRENT_TAGS" | jq -e "contains([${tag_id}])" > /dev/null 2>&1; then
            has_managed_tags=true
            break
        fi
    done

    if [ "$has_managed_tags" = "false" ]; then
        log "INFO" "Movie has no managed tags - nothing to remove"
    else
        log "INFO" "Removing managed tags from movie..."

        # Get fresh movie object
        movie_full=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")
        current_tags=$(echo "$movie_full" | jq -r '.tags')

        # Remove all managed tags
        for tag_id in "${managed_tag_ids[@]}"; do
            current_tags=$(echo "$current_tags" | jq "del(.[] | select(. == ${tag_id}))")
        done

        # Update movie
        updated_movie=$(echo "$movie_full" | jq ".tags = ${current_tags}")

        curl -s -X PUT "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$updated_movie" > /dev/null

        log "INFO" "Tags removed from primary Radarr"

        # Sync to secondary if enabled
        if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
            log "INFO" "Syncing tag removal to $SECONDARY_RADARR_NAME..."

            # Find movie in secondary
            secondary_movie=$(curl -s "${SECONDARY_RADARR_API_URL}/movie?apikey=${SECONDARY_RADARR_API_KEY}" | \
                jq -c ".[] | select(.tmdbId == ${MOVIE_TMDB_ID})")

            if [ -n "$secondary_movie" ]; then
                secondary_movie_id=$(echo "$secondary_movie" | jq -r '.id')
                secondary_current_tags=$(echo "$secondary_movie" | jq -r '.tags')

                log "INFO" "Found movie in $SECONDARY_RADARR_NAME (ID: $secondary_movie_id)"

                # Get managed tag IDs in secondary
                for tag_config in "${RELEASE_GROUPS[@]}"; do
                    TAG_NAME=$(echo "$tag_config" | cut -d: -f2)

                    secondary_tag_id=$(curl -s "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" | \
                        jq -r ".[] | select(.label == \"${TAG_NAME}\") | .id")

                    if [ -n "$secondary_tag_id" ]; then
                        secondary_current_tags=$(echo "$secondary_current_tags" | jq "del(.[] | select(. == ${secondary_tag_id}))")
                    fi
                done

                # Update secondary movie
                secondary_movie_full=$(curl -s "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}")
                updated_secondary=$(echo "$secondary_movie_full" | jq ".tags = ${secondary_current_tags}")

                curl -s -X PUT "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "$updated_secondary" > /dev/null

                log "INFO" "Tags removed from $SECONDARY_RADARR_NAME"
            else
                log "INFO" "Movie not found in $SECONDARY_RADARR_NAME"
            fi
        fi
    fi

    log "INFO" "============================================"
    log "INFO" "File delete cleanup completed"
    log "INFO" "============================================"

    exit 0
fi

################################################################################
# QUALITY/AUDIO FILTER FUNCTIONS
################################################################################

# Check if filename matches quality filters
# EXACT COPY FROM tagarr.sh v1.0.0
check_quality_match() {
    local f="$1"
    [ "$ENABLE_QUALITY_FILTER" != "true" ] && return 0

    # STRICT: Only match MA/Play WEB-DL patterns
    # Uses word boundaries (\b) to prevent matching "AMZN" as "MA" or "IMAX" as "MA"
    # Supports various separators: . - _
    # Pattern: (word boundary)(ma|play)(separator)web(dl variants)(separator)

    if [ "$ENABLE_MA_WEBDL" = "true" ]; then
        # Match: MA.WEBDL- or MA-WEBDL. or MA_WEBDL- or MA.WEB-DL. etc
        if echo "$f" | grep -Eqi '\bma[._-]web([-.]?dl)?[._-]'; then
            return 0
        fi
    fi

    if [ "$ENABLE_PLAY_WEBDL" = "true" ]; then
        # Match: Play.WEBDL- or Play-WEBDL. or Play_WEBDL- or Play.WEB-DL. etc
        if echo "$f" | grep -Eqi '\bplay[._-]web([-.]?dl)?[._-]'; then
            return 0
        fi
    fi

    return 1
}

# Check if filename matches audio filters
# EXACT COPY FROM tagarr.sh v1.0.0
check_audio_match() {
    local f="$1"
    [ "$ENABLE_AUDIO_FILTER" != "true" ] && return 0

    # STRICT: Reject transcoded/upmixed/encoded audio first
    # Uses word boundaries to avoid false positives
    if echo "$f" | grep -Eqi '\b(upmix|encode|transcode|lossy|converted|re-?encode)\b'; then
        return 1
    fi

    # TrueHD checks - RESPECTS CONFIGURATION
    # Only matches if explicitly enabled
    if [ "$ENABLE_TRUEHD_ATMOS" = "true" ] || [ "$ENABLE_TRUEHD" = "true" ]; then
        if echo "$f" | grep -Eqi '\btruehd\b'; then
            if echo "$f" | grep -Eqi '\batmos\b'; then
                # TrueHD Atmos - only pass if Atmos is enabled
                [ "$ENABLE_TRUEHD_ATMOS" = "true" ] && return 0
            else
                # TrueHD (non-Atmos) - only pass if non-Atmos is enabled
                [ "$ENABLE_TRUEHD" = "true" ] && return 0
            fi
        fi
    fi

    # DTS:X check with word boundary
    if [ "$ENABLE_DTS_X" = "true" ]; then
        if echo "$f" | grep -Eqi '\bdts[._-]?x\b'; then
            return 0
        fi
    fi

    # DTS-HD MA check - supports various separators
    if [ "$ENABLE_DTS_HD_MA" = "true" ]; then
        # Match: DTS-HD.MA or DTS-HD MA or DTS.HD.MA or DTS_HD_MA etc
        if echo "$f" | grep -Eqi '\bdts[._-]?hd[._-]?ma\b'; then
            return 0
        fi
    fi

    return 1
}

################################################################################
# MAIN SCRIPT
################################################################################

log "INFO" "============================================"
log "INFO" "Tagarr Import v${SCRIPT_VERSION}"
log "INFO" "Event: $EVENT_TYPE"
log "INFO" "============================================"

# Get movie details from primary Radarr
log "INFO" "Fetching movie details (ID: $MOVIE_ID)..."
movie_json=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")

if [ -z "$movie_json" ]; then
    log "ERROR" "Failed to fetch movie details from Radarr"
    exit 1
fi

MOVIE_TITLE=$(echo "$movie_json" | jq -r '.title')
MOVIE_YEAR=$(echo "$movie_json" | jq -r '.year')
MOVIE_TMDB_ID=$(echo "$movie_json" | jq -r '.tmdbId')
MOVIE_IMDB_ID=$(echo "$movie_json" | jq -r '.imdbId // ""')
MOVIE_CURRENT_TAGS=$(echo "$movie_json" | jq -r '.tags')

# Get poster URL (try multiple sources)
MOVIE_POSTER_URL=""
# Try remotePoster first
remote_poster=$(echo "$movie_json" | jq -r '.remotePoster // ""')
if [ -n "$remote_poster" ] && [ "$remote_poster" != "null" ] && [ "$remote_poster" != "" ]; then
    MOVIE_POSTER_URL="$remote_poster"
    log "INFO" "Poster URL from remotePoster: $MOVIE_POSTER_URL"
else
    # Try images array for poster
    poster_from_images=$(echo "$movie_json" | jq -r '.images[] | select(.coverType == "poster") | .remoteUrl // .url // "" | select(length > 0)' | head -1)
    if [ -n "$poster_from_images" ] && [ "$poster_from_images" != "null" ]; then
        MOVIE_POSTER_URL="$poster_from_images"
        log "INFO" "Poster URL from images array: $MOVIE_POSTER_URL"
    fi
fi

# Fallback to TMDb poster if still empty
if [ -z "$MOVIE_POSTER_URL" ] || [ "$MOVIE_POSTER_URL" = "null" ]; then
    if [ -n "$MOVIE_TMDB_ID" ] && [ "$MOVIE_TMDB_ID" != "null" ] && [ "$MOVIE_TMDB_ID" != "0" ]; then
        MOVIE_POSTER_URL="https://image.tmdb.org/t/p/w500/placeholder.jpg"
        log "INFO" "Using TMDb placeholder poster"
    else
        log "WARN" "No poster URL available"
    fi
fi

# Get file details
MOVIE_FILE_QUALITY=$(echo "$movie_json" | jq -r '.movieFile.quality.quality.name // "Unknown"')
MOVIE_FILE_SIZE_BYTES=$(echo "$movie_json" | jq -r '.movieFile.size // 0')
MOVIE_FILE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $MOVIE_FILE_SIZE_BYTES/1073741824}")
MOVIE_RELEASE_GROUP=$(echo "$movie_json" | jq -r '.movieFile.releaseGroup // "Unknown"')

log "INFO" "Movie: $MOVIE_TITLE ($MOVIE_YEAR)"
log "INFO" "File: $MOVIE_FILE_RELATIVE"

if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
    log "DEBUG" "Release group: $MOVIE_RELEASE_GROUP"
    log "DEBUG" "Quality: $MOVIE_FILE_QUALITY"
    log "DEBUG" "Size: ${MOVIE_FILE_SIZE_GB} GiB"
    log "DEBUG" "Scene: ${MOVIE_FILE_SCENE:-none}"
fi

# Get file info for matching
RELEASE_GROUP_FIELD=$(echo "$movie_json" | jq -r '.movieFile.releaseGroup // ""')

# Combine all sources for searching
COMBINED_NAME="${MOVIE_FILE_RELATIVE} ${MOVIE_FILE_SCENE}"
COMBINED_LOWER=$(echo "$COMBINED_NAME" | tr '[:upper:]' '[:lower:]')
RELEASE_GROUP_LOWER=$(echo "$RELEASE_GROUP_FIELD" | tr '[:upper:]' '[:lower:]')

log "INFO" "Checking release group matches..."

# Arrays to track what should happen
declare -a tags_to_add=()
declare -a tags_to_remove=()
declare -a tags_to_keep=()

# Check each release group
for tag_config in "${RELEASE_GROUPS[@]}"; do
    SEARCH_STRING=$(echo "$tag_config" | cut -d: -f1)
    TAG_NAME=$(echo "$tag_config" | cut -d: -f2)
    DISPLAY_NAME=$(echo "$tag_config" | cut -d: -f3)
    TAG_MODE=$(echo "$tag_config" | cut -d: -f4)

    # Defaults
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$TAG_NAME"
    [ -z "$TAG_MODE" ] && TAG_MODE="simple"

    search_lower=$(echo "$SEARCH_STRING" | tr '[:upper:]' '[:lower:]')

    # Check if release group matches (3 places)
    match_found=false
    match_location=""

    if echo "$COMBINED_LOWER" | grep -q "$search_lower"; then
        match_found=true
        match_location="filename/scene"
    elif [ -n "$RELEASE_GROUP_LOWER" ] && echo "$RELEASE_GROUP_LOWER" | grep -q "$search_lower"; then
        match_found=true
        match_location="release group field"
    fi

    # Get or create tag in primary
    primary_tag_id=$(curl -s "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" | \
        jq -r ".[] | select(.label == \"${TAG_NAME}\") | .id")

    if [ -z "$primary_tag_id" ]; then
        log "INFO" "Creating tag '$TAG_NAME' in $PRIMARY_RADARR_NAME..."
        new_tag=$(curl -s -X POST "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"label\": \"${TAG_NAME}\"}")
        primary_tag_id=$(echo "$new_tag" | jq -r '.id')
        log "INFO" "Created tag with ID: $primary_tag_id"
    fi

    # Check if movie currently has this tag
    movie_has_tag=$(echo "$MOVIE_CURRENT_TAGS" | jq "contains([${primary_tag_id}])")

    # Determine if movie SHOULD have this tag
    should_have_tag=false
    reason=""

    if [ "$match_found" = "true" ]; then
        if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            log "DEBUG" "Group match: $DISPLAY_NAME via $match_location"
        fi

        if [ "$TAG_MODE" = "simple" ]; then
            should_have_tag=true
            reason="$DISPLAY_NAME (simple mode)"
        elif [ "$TAG_MODE" = "filtered" ]; then
            # Check filters
            quality_ok=false
            audio_ok=false

            if check_quality_match "$MOVIE_FILE_RELATIVE"; then
                quality_ok=true
            fi

            if check_audio_match "$MOVIE_FILE_RELATIVE"; then
                audio_ok=true
            fi

            if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
                log "DEBUG" "  Quality filter: $quality_ok | Audio filter: $audio_ok"
            fi

            if [ "$quality_ok" = "true" ] && [ "$audio_ok" = "true" ]; then
                should_have_tag=true
                reason="$DISPLAY_NAME (passed filters)"
            else
                if [ "$quality_ok" = "false" ]; then
                    reason="$DISPLAY_NAME (failed quality filter)"
                elif [ "$audio_ok" = "false" ]; then
                    reason="$DISPLAY_NAME (failed audio filter)"
                fi
            fi
        fi
    fi

    # Decide action: add, keep, or remove
    if [ "$should_have_tag" = "true" ]; then
        if [ "$movie_has_tag" = "true" ]; then
            log "INFO" "Keeping tag: $reason"
            tags_to_keep+=("$TAG_NAME:$primary_tag_id:$DISPLAY_NAME")
        else
            log "INFO" "Adding tag: $reason"
            tags_to_add+=("$TAG_NAME:$primary_tag_id:$DISPLAY_NAME")
        fi
    else
        if [ "$movie_has_tag" = "true" ]; then
            log "INFO" "Removing tag: $reason"
            tags_to_remove+=("$TAG_NAME:$primary_tag_id:$DISPLAY_NAME")
        elif [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            if [ "$match_found" = "true" ]; then
                log "DEBUG" "Skipped: $reason"
            else
                log "DEBUG" "No match for $DISPLAY_NAME"
            fi
        fi
    fi
done

################################################################################
# DISCOVERY CHECK
################################################################################

discovered=false
discovered_group=""
discovered_quality=""
discovered_audio=""

if [ "${ENABLE_DISCOVERY:-false}" = "true" ] && [ -n "$RELEASE_GROUP_FIELD" ] && [ "$RELEASE_GROUP_FIELD" != "Unknown" ]; then
    rg_lower="${RELEASE_GROUP_FIELD,,}"

    # Skip if already known (active or commented in config)
    if [ -z "${known_release_groups[$rg_lower]:-}" ]; then
        if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            log "DEBUG" "Discovery: unknown group '$RELEASE_GROUP_FIELD' — checking filters"
        fi
        # Run quality + audio filters on the filename
        if check_quality_match "$MOVIE_FILE_RELATIVE" && check_audio_match "$MOVIE_FILE_RELATIVE"; then
            discovered=true
            discovered_group="$RELEASE_GROUP_FIELD"

            # Detect quality detail
            if echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bma[._-]web'; then
                discovered_quality="MA WEB-DL"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bplay[._-]web'; then
                discovered_quality="Play WEB-DL"
            else
                discovered_quality="Unknown WEB-DL"
            fi

            # Detect audio detail
            if echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\btruehd\b.*\batmos\b|\batmos\b.*\btruehd\b'; then
                discovered_audio="TrueHD Atmos"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bdts[._-]?x\b'; then
                discovered_audio="DTS-X"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\btruehd\b'; then
                discovered_audio="TrueHD"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bdts[._-]?hd[._-]?ma\b'; then
                discovered_audio="DTS-HD.MA"
            else
                discovered_audio="Lossless audio"
            fi

            log "INFO" "DISCOVERED: $discovered_group ($discovered_quality + $discovered_audio)"

            # Write commented entry to config file
            today=$(date '+%Y-%m-%d')
            rg_key="${rg_lower}"
            insert_line="    #\"${rg_key}:${rg_key}:${discovered_group}:filtered\"              # Discovered ${today}: ${discovered_quality} + ${discovered_audio}"

            # Find the closing ) of RELEASE_GROUPS array
            rg_start_line=$(grep -n 'RELEASE_GROUPS=(' "$CONFIG_FILE" | head -n1 | cut -d: -f1)

            if [ -n "$rg_start_line" ]; then
                rg_close_line=$(tail -n +"$rg_start_line" "$CONFIG_FILE" | grep -n '^)' | head -n1 | cut -d: -f1)

                if [ -n "$rg_close_line" ]; then
                    # Convert to absolute line number
                    rg_close_line=$(( rg_start_line + rg_close_line - 1 ))

                    # Insert before the closing )
                    tmp_file="${CONFIG_FILE}.tmp"
                    {
                        head -n $(( rg_close_line - 1 )) "$CONFIG_FILE"
                        echo "$insert_line"
                        tail -n +"$rg_close_line" "$CONFIG_FILE"
                    } > "$tmp_file"
                    mv "$tmp_file" "$CONFIG_FILE"

                    log "INFO" "Written discovered group to config: $discovered_group"
                else
                    log "WARN" "Could not find closing ) for RELEASE_GROUPS in config"
                fi
            else
                log "WARN" "Could not find RELEASE_GROUPS=( in config"
            fi
        elif [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            log "DEBUG" "Discovery: '$RELEASE_GROUP_FIELD' failed filters — not discovered"
        fi
    elif [ "${ENABLE_DEBUG:-false}" = "true" ]; then
        log "DEBUG" "Discovery: '$RELEASE_GROUP_FIELD' already known — skipped"
    fi
fi

################################################################################
# APPLY TAG CHANGES IN PRIMARY
################################################################################

if [ ${#tags_to_add[@]} -gt 0 ]; then
    log "INFO" "Applying ${#tags_to_add[@]} new tags to movie..."

    # Get fresh movie object
    movie_full=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")
    current_tags=$(echo "$movie_full" | jq -r '.tags')

    for tag_info in "${tags_to_add[@]}"; do
        tag_id=$(echo "$tag_info" | cut -d: -f2)
        current_tags=$(echo "$current_tags" | jq ". += [${tag_id}] | unique")
    done

    # Update movie with new tags
    updated_movie=$(echo "$movie_full" | jq ".tags = ${current_tags}")

    curl -s -X PUT "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$updated_movie" > /dev/null

    log "INFO" "Tags added successfully"
fi

if [ ${#tags_to_remove[@]} -gt 0 ]; then
    log "INFO" "Removing ${#tags_to_remove[@]} outdated tags from movie..."

    # Get fresh movie object
    movie_full=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")
    current_tags=$(echo "$movie_full" | jq -r '.tags')

    for tag_info in "${tags_to_remove[@]}"; do
        tag_id=$(echo "$tag_info" | cut -d: -f2)
        current_tags=$(echo "$current_tags" | jq "del(.[] | select(. == ${tag_id}))")
    done

    # Update movie with cleaned tags
    updated_movie=$(echo "$movie_full" | jq ".tags = ${current_tags}")

    curl -s -X PUT "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$updated_movie" > /dev/null

    log "INFO" "Tags removed successfully"
fi

################################################################################
# SYNC TO SECONDARY
################################################################################

SECONDARY_STATUS="disabled"
if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    log "INFO" "Syncing tags to $SECONDARY_RADARR_NAME..."

    # Find movie in secondary by TMDb ID
    secondary_movie=$(curl -s "${SECONDARY_RADARR_API_URL}/movie?apikey=${SECONDARY_RADARR_API_KEY}" | \
        jq -c ".[] | select(.tmdbId == ${MOVIE_TMDB_ID})")

    if [ -n "$secondary_movie" ]; then
        secondary_movie_id=$(echo "$secondary_movie" | jq -r '.id')
        secondary_current_tags=$(echo "$secondary_movie" | jq -r '.tags')

        log "INFO" "Found movie in $SECONDARY_RADARR_NAME (ID: $secondary_movie_id)"

        # Process each tag for secondary
        for tag_info in "${tags_to_add[@]}"; do
            tag_name=$(echo "$tag_info" | cut -d: -f1)

            # Get or create tag in secondary
            secondary_tag_id=$(curl -s "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" | \
                jq -r ".[] | select(.label == \"${tag_name}\") | .id")

            if [ -z "$secondary_tag_id" ]; then
                new_tag=$(curl -s -X POST "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "{\"label\": \"${tag_name}\"}")
                secondary_tag_id=$(echo "$new_tag" | jq -r '.id')
            fi

            secondary_current_tags=$(echo "$secondary_current_tags" | jq ". += [${secondary_tag_id}] | unique")
        done

        # Remove tags in secondary
        for tag_info in "${tags_to_remove[@]}"; do
            tag_name=$(echo "$tag_info" | cut -d: -f1)

            secondary_tag_id=$(curl -s "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" | \
                jq -r ".[] | select(.label == \"${tag_name}\") | .id")

            if [ -n "$secondary_tag_id" ]; then
                secondary_current_tags=$(echo "$secondary_current_tags" | jq "del(.[] | select(. == ${secondary_tag_id}))")
            fi
        done

        # Update secondary movie
        secondary_movie_full=$(curl -s "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}")
        updated_secondary=$(echo "$secondary_movie_full" | jq ".tags = ${secondary_current_tags}")

        curl -s -X PUT "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$updated_secondary" > /dev/null

        log "INFO" "Tags synced to $SECONDARY_RADARR_NAME"
        SECONDARY_STATUS="synced"
    else
        log "INFO" "Movie not found in $SECONDARY_RADARR_NAME"
        SECONDARY_STATUS="not_found"
    fi
fi

################################################################################
# BUILD SUMMARY
################################################################################

tags_added_list=""
tags_removed_list=""
tags_kept_list=""

for tag_info in "${tags_to_add[@]}"; do
    display=$(echo "$tag_info" | cut -d: -f3)
    tags_added_list="${tags_added_list}${display}, "
done
tags_added_list=${tags_added_list%, }

for tag_info in "${tags_to_remove[@]}"; do
    display=$(echo "$tag_info" | cut -d: -f3)
    tags_removed_list="${tags_removed_list}${display}, "
done
tags_removed_list=${tags_removed_list%, }

for tag_info in "${tags_to_keep[@]}"; do
    display=$(echo "$tag_info" | cut -d: -f3)
    tags_kept_list="${tags_kept_list}${display}, "
done
tags_kept_list=${tags_kept_list%, }

# Final summary
log "INFO" "============================================"
log "INFO" "Summary:"
[ -n "$tags_added_list" ] && log "INFO" "  Added: $tags_added_list"
[ -n "$tags_kept_list" ] && log "INFO" "  Kept: $tags_kept_list"
[ -n "$tags_removed_list" ] && log "INFO" "  Removed: $tags_removed_list"
[ -z "$tags_added_list" ] && [ -z "$tags_kept_list" ] && [ -z "$tags_removed_list" ] && log "INFO" "  No tags applied"
[ "$discovered" = "true" ] && log "INFO" "  Discovered: $discovered_group ($discovered_quality + $discovered_audio)"
log "INFO" "  Secondary: $SECONDARY_STATUS"
log "INFO" "============================================"

################################################################################
# DISCORD NOTIFICATION (smart — only when something happened)
################################################################################

tagged=$( [ ${#tags_to_add[@]} -gt 0 ] || [ ${#tags_to_keep[@]} -gt 0 ] && echo true || echo false )

# Handle Radarr Test event — always send a confirmation notification
if [ "$DISCORD_ENABLED" = "true" ] && [ "$EVENT_TYPE" = "Test" ]; then
    log "INFO" "Sending Discord test notification..."

    payload=$(jq -n \
        --argjson color 16753920 \
        --arg footer_text "Tagarr Import • $(date '+%d-%m-%Y %H:%M')" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            embeds: [{
                title: "Tagarr Import v'"${SCRIPT_VERSION}"' — Test OK",
                color: $color,
                fields: [
                    { name: "Status", value: "Connection successful", inline: true },
                    { name: "Discovery", value: "'"${ENABLE_DISCOVERY:-false}"'", inline: true }
                ],
                footer: { text: $footer_text },
                timestamp: $timestamp
            }]
        }')

    response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload")

    http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log "INFO" "Discord test notification sent successfully"
    else
        log "WARN" "Discord test notification failed (HTTP $http_code)"
    fi

    log "INFO" "Script completed successfully"
    exit 0
fi

if [ "$DISCORD_ENABLED" = "true" ] && { [ "$tagged" = "true" ] || [ "$discovered" = "true" ]; }; then
    log "INFO" "Sending Discord notification..."

    # Determine title and color
    if [ "$tagged" = "true" ] && [ "$discovered" = "true" ]; then
        notif_title="Tagged + Discovered - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16753920  # Orange (0xFFA500)
    elif [ "$discovered" = "true" ]; then
        notif_title="Discovered - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16766720  # Gold (0xFFD700)
    else
        notif_title="Tagged - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16753920  # Orange (0xFFA500)
    fi

    # Build tag summary
    tag_summary=""
    if [ -n "$tags_added_list" ]; then
        tag_summary="${tags_added_list}"
    fi
    if [ -n "$tags_kept_list" ]; then
        if [ -n "$tag_summary" ]; then
            tag_summary="${tag_summary}, ${tags_kept_list}"
        else
            tag_summary="${tags_kept_list}"
        fi
    fi
    [ -z "$tag_summary" ] && tag_summary="None"

    # Build instance info
    instance_value=""
    if [ "$tagged" = "true" ]; then
        if [ "$SECONDARY_STATUS" = "synced" ]; then
            instance_value="${PRIMARY_RADARR_NAME} + ${SECONDARY_RADARR_NAME}"
        else
            instance_value="${PRIMARY_RADARR_NAME}"
        fi
    else
        instance_value="None"
    fi

    # Build fields array — base fields always present
    fields_json=$(jq -n \
        --arg instance_value "$instance_value" \
        --arg tag_summary "$tag_summary" \
        --arg event_type "$EVENT_TYPE" \
        --arg filename "$MOVIE_FILE_RELATIVE" \
        '[
            { name: "Tagged in", value: $instance_value, inline: false },
            { name: "Tags Applied", value: $tag_summary, inline: true },
            { name: "Event", value: $event_type, inline: true },
            { name: "Filename", value: $filename, inline: false }
        ]')

    # Add discovery field if applicable
    if [ "$discovered" = "true" ]; then
        discovery_value="${discovered_group} — added to config"
        fields_json=$(echo "$fields_json" | jq \
            --arg disc_value "$discovery_value" \
            '. += [{ name: "Discovered Group", value: $disc_value, inline: false }]')
    fi

    # Build Discord embed payload
    payload=$(jq -n \
        --arg title "$notif_title" \
        --argjson color "$notif_color" \
        --arg poster_url "$MOVIE_POSTER_URL" \
        --argjson fields "$fields_json" \
        --arg footer_text "Tagarr Import • $(date '+%d-%m-%Y %H:%M')" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: {
                    text: $footer_text
                },
                timestamp: $timestamp,
                thumbnail: {
                    url: $poster_url
                }
            }]
        }')

    response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload")

    http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log "INFO" "Discord notification sent successfully"
    else
        log "WARN" "Discord notification failed (HTTP $http_code)"
    fi
elif [ "$DISCORD_ENABLED" = "true" ]; then
    log "INFO" "No tags applied and nothing discovered - skipping Discord notification"
fi

log "INFO" "Script completed successfully"
exit 0
