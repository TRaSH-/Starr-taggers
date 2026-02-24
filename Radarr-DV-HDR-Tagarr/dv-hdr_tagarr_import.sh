#!/usr/bin/env bash

# Advanced Radarr DV + HDR Tagging Script for Individual Movies
# Executes automatically when Radarr downloads/upgrades/downgrades movies
# 
# Features:
# - Complete HDR format detection (SDR, HDR10, HDR10+, PQ, DV)
# - Dolby Vision Profile detection (MEL, FEL, Profile 8)
# - CM version detection (CM 2.x, CM 4.0)
# - Configurable tag categories with cleanup logic
# - Automatic removal of disabled category tags
#
# By jpalenz77 from the TRaSH discord based on the work of mvanbaak
# Enhanced with granular category control and advanced DV detection
#
# Version 2.0.0 (Released 2025-12-21)
#   * Complete rewrite with advanced logic
#   * Added configurable tag categories
#   * Enhanced DV Profile and CM detection
#   * Automatic cleanup of disabled categories

# ========== CONFIGURATION ==========
# Script directory
SCRIPT_DIR=$(dirname "$0")

# Load configuration file if it exists
if [ -f "${SCRIPT_DIR}/scripts.conf" ]; then
    . "${SCRIPT_DIR}/scripts.conf"
fi

# === FEATURE TOGGLES ===
# Enable/disable tag categories (true/false)
: "${ENABLE_HDR_FORMATS_TAGS:=true}"    # SDR, PQ, HDR10, HDR10+, DV tags
: "${ENABLE_NO_DV_TAGS:=false}"         # No-DV tags  
: "${ENABLE_PROFILE_TAGS:=true}"        # MEL, FEL tags
: "${ENABLE_PROFILE8_TAGS:=false}"      # DVProfile8 tags
: "${ENABLE_CM_TAGS:=true}"             # CM2, CM4 tags

# === API CONFIGURATION ===
# Radarr connection settings
: "${RADARR_API_URL:=http://radarr:7878/api/v3}"
: "${RADARR_API_KEY:=xxxxx}"

# === PATH CONFIGURATION ===
# Container media path (path inside container)
: "${CONTAINER_MEDIA_PATH:=/data/media}"
# Host media path (path on host system)
: "${HOST_MEDIA_PATH:=/mnt/user/data/media}"

# === LOGGING CONFIGURATION ===
: "${LOG_FILE:=${SCRIPT_DIR}/logs/dv-hdr_tagarr_import.log}"

# === ADVANCED SETTINGS ===
# Timeouts and limits (configurable via scripts.conf)
: "${RPU_EXTRACTION_TIMEOUT:=30}"
: "${RPU_ANALYSIS_TIMEOUT:=10}"
: "${MAX_FRAMES_ANALYZE:=100}"

# Event information from Radarr
EVENT_TYPE="${radarr_eventtype:-"Test"}"
MOVIE_ID="${radarr_movie_id:-0}"
MOVIE_FILE="${radarr_moviefile_path:-""}"

# Global variables
NEEDED_EXECUTABLES="curl dovi_tool ffmpeg grep jq mktemp"

# ========== LOGGING ==========
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"
}

# ========== UTILITY FUNCTIONS ==========
validate_configuration() {
    local config_valid=true
    
    log "INFO" "Validating configuration..."
    
    # Check API configuration
    if [ "$RADARR_API_KEY" = "YOUR_API_KEY_HERE" ]; then
        log "WARN" "  → API Key not configured in scripts.conf"
        log "WARN" "  → Using environment/default values"
    fi
    
    # Test API connection (this is the real test)
    if ! curl -s --connect-timeout 5 "${RADARR_API_URL}/system/status?apikey=${RADARR_API_KEY}" >/dev/null 2>&1; then
        log "ERROR" "  → Cannot connect to Radarr API at ${RADARR_API_URL}"
        log "ERROR" "  → Check RADARR_API_URL and RADARR_API_KEY configuration"
        config_valid=false
    else
        log "INFO" "  → API connection successful"
    fi
    
    # Check path configuration (only when not in container)
    if [ ! -f "/.dockerenv" ] && ! grep -q docker /proc/1/cgroup 2>/dev/null; then
        if [ ! -d "$HOST_MEDIA_PATH" ]; then
            log "WARN" "  → Host media path does not exist: $HOST_MEDIA_PATH"
            log "WARN" "  → Check HOST_MEDIA_PATH in scripts.conf"
            config_valid=false
        else
            log "INFO" "  → Host media path found: $HOST_MEDIA_PATH"
        fi
    fi
    
    # Log configuration summary
    log "INFO" "Configuration summary:"
    log "INFO" "  → API URL: $RADARR_API_URL"
    log "INFO" "  → Container path: $CONTAINER_MEDIA_PATH"  
    log "INFO" "  → Host path: $HOST_MEDIA_PATH"
    log "INFO" "  → Log file: $LOG_FILE"
    log "INFO" "  → HDR Format Tags: $ENABLE_HDR_FORMATS_TAGS"
    log "INFO" "  → Profile Tags: $ENABLE_PROFILE_TAGS"
    log "INFO" "  → CM Tags: $ENABLE_CM_TAGS"
    
    if [ "$config_valid" != "true" ]; then
        log "ERROR" "Configuration validation failed. Please check scripts.conf"
        log "ERROR" "See README.md for configuration examples"
        exit 1
    fi
    
    log "INFO" "Configuration validation successful"
}

check_needed_executables() {
    for executable in ${NEEDED_EXECUTABLES}; do
        if ! command -v "${executable}" >/dev/null 2>&1; then
            log "ERROR" "Executable '${executable}' not found."
            log "ERROR" "Please install missing dependencies. See README.md"
            exit 127
        fi
    done
}

translate_path() {
    # Convert container path to host path based on configuration
    local input_path="$1"
    
    # If running inside container, don't translate paths
    if [ -f "/.dockerenv" ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        # Running inside container - use path as-is
        echo "$input_path"
    else
        # Running on host - translate path using configured paths
        echo "$input_path" | sed "s|^${CONTAINER_MEDIA_PATH}|${HOST_MEDIA_PATH}|"
    fi
}

# ========== API FUNCTIONS ==========
get_tag_id() {
    curl -s "${RADARR_API_URL}/tag?apikey=${RADARR_API_KEY}" | jq -r ".[] | select(.label == \"$1\") | .id"
}

create_tag() {
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"label\": \"$1\"}" \
        "${RADARR_API_URL}/tag?apikey=${RADARR_API_KEY}" | jq -r ".id"
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
    curl -s "${RADARR_API_URL}/movie/${movie_id}?apikey=${RADARR_API_KEY}" | \
        jq -e ".tags | index(${tag_id})" >/dev/null 2>&1
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
            "${RADARR_API_URL}/movie/editor?apikey=${RADARR_API_KEY}" >/dev/null
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
            "${RADARR_API_URL}/movie/editor?apikey=${RADARR_API_KEY}" >/dev/null
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
            "${RADARR_API_URL}/movie/editor?apikey=${RADARR_API_KEY}" >/dev/null
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

# ========== DV ANALYSIS ==========
extract_rpu() {
    local file="$1"
    log "INFO" "  → extract_rpu called with: $file"
    
    if [ ! -f "$file" ]; then
        log "WARN" "  → File does not exist: $file"
        return 1
    fi
    
    log "INFO" "  → File exists, checking permissions..."
    ls -la "$file" 2>/dev/null | log "INFO" "  → File info: $(cat)"
    
    # Create temp directory if it doesn't exist
    local script_dir="$(dirname "$0")"
    [ ! -d "$script_dir/tmp" ] && mkdir -p "$script_dir/tmp" 2>/dev/null
    
    # Use script directory for temp file to ensure proper permissions
    local temp_rpu=$(mktemp -p "$script_dir" .rpu.XXXXXX)
    
    log "INFO" "  → Attempting RPU extraction from: $file"
    log "INFO" "  → Using temp file: $temp_rpu"
    log "INFO" "  → Temp file permissions: $(ls -la "$temp_rpu" 2>/dev/null || echo 'failed to check')"
    
    # Test if dovi_tool is accessible
    if ! command -v dovi_tool >/dev/null 2>&1; then
        log "WARN" "  → dovi_tool command not found"
        rm -f "$temp_rpu"
        return 1
    fi
    
    # Test if ffmpeg is accessible
    if ! command -v ffmpeg >/dev/null 2>&1; then
        log "WARN" "  → ffmpeg command not found"
        rm -f "$temp_rpu"
        return 1
    fi
    
    log "INFO" "  → Starting RPU extraction with timeout..."  
    timeout "$RPU_EXTRACTION_TIMEOUT" ffmpeg -loglevel error -i "$file" -c:v copy -vbsf hevc_mp4toannexb -f hevc -frames:v "$MAX_FRAMES_ANALYZE" - 2>/dev/null | \
        timeout "$RPU_EXTRACTION_TIMEOUT" dovi_tool extract-rpu - -o "$temp_rpu" 2>&1
    local extraction_result=$?
    
    log "INFO" "  → Extraction command exit code: $extraction_result"
    
    if [ $extraction_result -ne 0 ]; then
        log "WARN" "  → RPU extraction failed with code: $extraction_result"
        rm -f "$temp_rpu"
        return 1
    fi
    
    if [ ! -f "$temp_rpu" ]; then
        log "WARN" "  → Temp RPU file was not created"
        return 1
    fi
    
    log "INFO" "  → RPU file created, size: $(stat -c%s "$temp_rpu" 2>/dev/null || echo 'unknown')"
    
    log "INFO" "  → RPU extraction successful, analyzing..."
    local summary=$(timeout "$RPU_ANALYSIS_TIMEOUT" dovi_tool info -i "$temp_rpu" --summary 2>&1)
    local analysis_result=$?
    
    log "INFO" "  → Analysis command exit code: $analysis_result"
    
    rm -f "$temp_rpu"
    
    if [ $analysis_result -ne 0 ]; then
        log "WARN" "  → RPU analysis failed with code: $analysis_result"
        return 1
    fi
    
    if [ -z "$summary" ]; then
        log "WARN" "  → RPU analysis failed (empty summary)"
        return 1
    fi
    
    log "INFO" "  → RPU analysis successful"
    echo "$summary"
}

# ========== MAIN PROCESSING ==========
process_movie() {
    local movie_id=$1
    local movie_file_path="$2"
    
    log "INFO" "Processing movie ID: $movie_id"
    log "INFO" "Event: $EVENT_TYPE"
    
    # First, clean up any tags from disabled categories
    clean_disabled_categories "$movie_id"
    
    # Handle file deletion events
    if [ "$EVENT_TYPE" = "MovieFileDelete" ]; then
        log "INFO" "File deleted - cleaning all DV/HDR tags"
        # Remove all tags since there's no file to analyze
        for tag in "sdr" "hdr10" "hdr10plus" "pq" "dv" "no-dv" "mel" "fel" "dvprofile8" "cm2" "cm4"; do
            force_remove_tag "$movie_id" "$tag"
        done
        return 0
    fi
    
    # Validate movie file
    if [ -z "$movie_file_path" ] || [ ! -f "$movie_file_path" ]; then
        log "WARN" "No valid movie file provided or file doesn't exist: $movie_file_path"
        return 1
    fi
    
    # Get movie info from API to check HDR type
    local movie_json=$(curl -s "${RADARR_API_URL}/movie/${movie_id}?apikey=${RADARR_API_KEY}")
    local hdr_type=$(echo "$movie_json" | jq -r '.movieFile.mediaInfo.videoDynamicRangeType // empty')
    
    log "INFO" "  File: $(basename "$movie_file_path")"
    log "INFO" "  HDR Type from API: ${hdr_type:-SDR}"
    
    # Determine if content has DV according to API
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
        local host_file=$(translate_path "$movie_file_path")
        log "INFO" "  → Translated path: $host_file"
        log "INFO" "  → About to call extract_rpu..."
        local dv_summary=$(extract_rpu "$host_file")
        log "INFO" "  → extract_rpu returned with exit code: $?"
        
        if [ -n "$dv_summary" ]; then
            # DOLBY VISION DETECTED
            log "INFO" "  → DV confirmed"
            remove_tag "$movie_id" "no-dv"
            add_tag "$movie_id" "dv"
            
            # Debug: show complete dovi_tool output
            log "INFO" "  DV SUMMARY:"
            echo "$dv_summary" | while read line; do
                [ -n "$line" ] && log "INFO" "    $line"
            done
            
            # Check Profile and Enhancement Layer - corrected logic
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
    
    log "INFO" "  ✓ Done processing movie $movie_id"
}

# ========== MAIN SCRIPT FLOW ==========
check_needed_executables
validate_configuration

# Override with command line arguments if provided
if [ -n "$1" ]; then
    EVENT_TYPE="$1"
fi

if [ -n "$2" ]; then
    MOVIE_ID="$2"
fi

if [ -n "$3" ]; then
    MOVIE_FILE="$3"
fi

# Log script start
log "INFO" "==================== Auto Tagging Script Started ===================="
log "INFO" "Event Type: $EVENT_TYPE"
log "INFO" "Movie ID: $MOVIE_ID"
log "INFO" "Movie File: $MOVIE_FILE"
log "INFO" "Tag Categories Enabled:"
log "INFO" "  HDR Format Tags: $ENABLE_HDR_FORMATS_TAGS"
log "INFO" "  No-DV Tags: $ENABLE_NO_DV_TAGS" 
log "INFO" "  Profile Tags: $ENABLE_PROFILE_TAGS"
log "INFO" "  Profile 8 Tags: $ENABLE_PROFILE8_TAGS"
log "INFO" "  CM Tags: $ENABLE_CM_TAGS"

case "${EVENT_TYPE}" in
    Test)
        log "INFO" "Received test event - signal success"
        exit 0
        ;;
    MovieFileDelete)
        log "INFO" "Got event ${EVENT_TYPE} - cleaning tags"
        process_movie "${MOVIE_ID}" ""
        ;;
    Download|Upgrade|ManualImport)
        log "INFO" "Got event ${EVENT_TYPE} - processing movie"
        process_movie "${MOVIE_ID}" "${MOVIE_FILE}"
        ;;
    *)
        log "ERROR" "Got unknown event ${EVENT_TYPE} - exiting"
        exit 4
        ;;
esac

log "INFO" "==================== Auto Tagging Script Completed ===================="