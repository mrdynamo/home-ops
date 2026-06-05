#!/usr/bin/env bash
# Emby Recording Post-Processor
# Detects split recordings (caused by Dispatcharr/Emby restarts mid-recording)
# and renames them with -part1/-part2/... suffixes for Plex multi-part file
# compatibility.
#
# Configure in Emby: Dashboard > Live TV > Recording Post Processing
#   Command:   /config/scripts/recording-post-processor.sh
#   Arguments: {path}

set -euo pipefail

readonly LOG_FILE="/tmp/emby-post-process.log"
readonly VIDEO_EXTENSIONS="ts mkv mp4 avi m2ts"
readonly SIDE_EXTENSIONS="nfo"
# Max mtime gap (seconds) for files to be considered the same recording session.
readonly MAX_AGE_DIFF=21600

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-process] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

stable_key() {
    local stem="$1"
    # Remove existing Plex suffix and Emby split counter suffixes.
    stem=$(echo "$stem" | sed -E 's/[[:space:]]*-[Pp][Aa][Rr][Tt][0-9]+$//')
    stem=$(echo "$stem" | sed -E 's/[[:space:]]*-[[:space:]]*[0-9]+$//')
    # Remove trailing " (N)" counter style.
    stem=$(echo "$stem" | sed -E 's/ \([0-9]+\)$//')
    # Cleanup trailing separators.
    stem=$(echo "$stem" | sed -E 's/[[:space:]_-]+$//')
    echo "$stem"
}

canonical_base_name() {
    local session_key="$1"
    local base="$session_key"
    local y="" m="" d="" title=""

    # Extract title + timestamp if Emby included YYYY_MM_DD_HH_MM_SS.
    if [[ "$session_key" =~ ^(.*)[[:space:]_]([0-9]{4})[_-]([0-9]{2})[_-]([0-9]{2})[_-]([0-9]{2})[_-]([0-9]{2})[_-]([0-9]{2})(.*)$ ]]; then
        title="${BASH_REMATCH[1]}"
        y="${BASH_REMATCH[2]}"
        m="${BASH_REMATCH[3]}"
        d="${BASH_REMATCH[4]}"
        title=$(echo "$title" | sed -E 's/[[:space:]_-]+$//')

        # For episodic content (SxxEyy / 1x02), keep title only.
        # For daily/news/live style, append air date so each day stays unique.
        if [[ "$title" =~ [Ss][0-9]{1,2}[Ee][0-9]{1,2} ]] || [[ "$title" =~ [0-9]{1,2}x[0-9]{1,2} ]]; then
            base="$title"
        else
            base="${title} - ${y}-${m}-${d}"
        fi
    fi

    base=$(echo "$base" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]_-]+$//')
    echo "$base"
}

file_mtime() { stat --format="%Y" "$1"; }

is_video() {
    local ext="${1##*.}"
    ext="${ext,,}"
    local e
    for e in $VIDEO_EXTENSIONS; do [[ "$e" == "$ext" ]] && return 0; done
    return 1
}

is_sidecar() {
    local ext="${1##*.}"
    ext="${ext,,}"
    local e
    for e in $SIDE_EXTENSIONS; do [[ "$e" == "$ext" ]] && return 0; done
    return 1
}

main() {
    local recording_path="${1:?Usage: $0 <recording_path>}"
    log "════════ Post-processing started ════════"
    log "Input: $recording_path"
    [[ -f "$recording_path" ]] || die "File not found: $recording_path"
    is_video "$recording_path" || die "Not a recognised video file: $recording_path"

    local dir file ext stem session_key final_base
    dir="$(dirname "$recording_path")"
    file="$(basename "$recording_path")"
    ext="${file##*.}"
    stem="${file%.$ext}"
    session_key="$(stable_key "$stem")"
    final_base="$(canonical_base_name "$session_key")"
    log "Session key: \"$session_key\""
    log "Final base:  \"$final_base\""
    log "Directory:   $dir"

    declare -a candidates=()
    declare -A mtime_map=()
    while IFS= read -r -d '' f; do
        local fname fext fstem fkey
        fname="$(basename "$f")"
        fext="${fname##*.}"
        fstem="${fname%.$fext}"
        is_video "$f" || continue
        fkey="$(stable_key "$fstem")"
        if [[ "$fkey" == "$session_key" ]]; then
            candidates+=("$f")
            mtime_map["$f"]="$(file_mtime "$f")"
            log "  Candidate: $fname  (key: \"$fkey\", mtime: ${mtime_map[$f]})"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0)

    local count="${#candidates[@]}"
    log "Found $count candidate(s)"
    [[ $count -eq 0 ]] && die "No candidates found"

    if [[ $count -eq 1 ]]; then
        log "Single file — no renaming required."
        log "════════ Post-processing complete ════════"
        exit 0
    fi

    local newest_mtime=0
    local f
    for f in "${candidates[@]}"; do
        local mt="${mtime_map[$f]}"
        (( mt > newest_mtime )) && newest_mtime=$mt
    done

    declare -a valid=()
    for f in "${candidates[@]}"; do
        local diff=$(( newest_mtime - mtime_map[$f] ))
        if (( diff <= MAX_AGE_DIFF )); then
            valid+=("$f")
        else
            log "  Excluding (${diff}s older than newest): $(basename "$f")"
        fi
    done

    local valid_count="${#valid[@]}"
    if [[ $valid_count -le 1 ]]; then
        log "Only $valid_count valid candidate(s) after time filter — no renaming."
        log "════════ Post-processing complete ════════"
        exit 0
    fi

    mapfile -t sorted < <(
        for f in "${valid[@]}"; do
            printf '%s\t%s\n' "${mtime_map[$f]}" "$f"
        done | sort -n | cut -f2
    )

    log "Renaming ${#sorted[@]} part(s)..."

    declare -a phase2=()
    local i
    for i in "${!sorted[@]}"; do
        local src="${sorted[$i]}"
        local src_ext="${src##*.}"
        local part=$(( i + 1 ))
        local final_name="${final_base}-part${part}.${src_ext}"
        local final_path="${dir}/${final_name}"
        local tmp_path="/tmp/.emby_pp_${$}_${i}.${src_ext}"
        log "  Phase1: $(basename "$src") -> $(basename "$tmp_path")"
        mv "$src" "$tmp_path"
        phase2+=("${tmp_path}|${final_path}")

        # Rename matching sidecar metadata file with the same part index.
        local src_stem="${src%.*}"
        local src_nfo="${src_stem}.nfo"
        if [[ -f "$src_nfo" ]] && is_sidecar "$src_nfo"; then
            local final_nfo="${dir}/${final_base}-part${part}.nfo"
            local tmp_nfo="/tmp/.emby_pp_${$}_${i}.nfo"
            log "  Phase1: $(basename "$src_nfo") -> $(basename "$tmp_nfo")"
            mv "$src_nfo" "$tmp_nfo"
            phase2+=("${tmp_nfo}|${final_nfo}")
        fi
    done

    local pair
    for pair in "${phase2[@]}"; do
        local tmp_path="${pair%%|*}"
        local final_path="${pair##*|}"
        log "  Phase2: $(basename "$tmp_path") -> $(basename "$final_path")"
        mv "$tmp_path" "$final_path"
    done

    log "════════ Post-processing complete ════════"
    log "Final files:"
    for f in "${dir}/${final_base}-part"*.*; do
        [[ -f "$f" ]] && log "  $(basename "$f")"
    done
}

main "$@"
