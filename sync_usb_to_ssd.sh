#!/usr/bin/env bash

set -euo pipefail

# === Configurable parameters ===
CHUNK_SIZE_MB=4000
STATE_DIR=".sync_usb_to_ssd_state"
TEMP_DIR=".sync_usb_to_ssd_tmp"
DONE_DIR=".sync_usb_chunks"
MAX_RETRIES=2

# === Global flags (default values) ===
NORESUME=false
QUIET=false
VERBOSE=false

# === Usage message ===
usage() {
  cat <<EOF
Usage: $0 [--noresume] [--quiet] [--verbose] [--help]

Options:
  --noresume   Restart from scratch (ignore any previous progress).
  --quiet      Suppress non-error messages.
  --verbose    Show rsync and progress output.
  --help       Show this help message.
EOF
}

# === Parse arguments ===
for arg in "$@"; do
  case "$arg" in
    --noresume) NORESUME=true ;;
    --quiet) QUIET=true ;;
    --verbose) VERBOSE=true ;;
    --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $arg"; usage; exit 1 ;;
  esac
done

# === Log and utility functions ===
log() {
  $QUIET || printf '[*] %s\n' "$*"
}

log_prompt() {
  printf '[*] %s\n' "$*"
}

prompt_insert_device() {

  local label="$1"
  local insert_emoji="📥"

  log_prompt "$insert_emoji Please plug in the $label and press enter to continue."
  read -r && printf "\033[A\r"

}

detect_newly_mounted_device() {

  local label="$1"
  shift
  local before_mounts=("$@")
  local check_emoji="✅"
  local mount_label

  mount_label=$(wait_for_new_mount "${before_mounts[@]}")
  log "$check_emoji $label mounted as $mount_label"

  echo "$mount_label"

}

safely_unmount_device() {

  local label="$1"
  local mount_point="$2"
  local check_emoji="✅"
  local dev

  sleep 1
  dev="$(lsblk -no PKNAME "$(findmnt -no SOURCE "$mount_point")")"
  udisksctl unmount -b "$dev" >/dev/null 2>&1 || true
  udisksctl power-off -b "$dev" >/dev/null 2>&1 || true
  log "$check_emoji $label unmounted. It is now safe to unplug it."

}

prompt_unplug_device() {

  local label="$1"
  local unplug_emoji="🔌"

  log_prompt "$unplug_emoji Please unplug the $label and press enter to continue."
  read -r && printf "\033[A\r"
  sleep 2

}

wait_for_new_mount() {

  local before_mounts=("$@")
  local after_mounts=()
  local label=""

  while true; do
    sleep 1
    mapfile -t after_mounts < <(ls "/media/$USER" 2>/dev/null)
    for label in "${after_mounts[@]}"; do
      if [[ ! " ${before_mounts[*]} " =~ " $label " ]]; then
        echo "$label"
        return
      fi
    done
  done

}

generate_chunk_lists() {

  local current_size=0
  local chunk_index=0
  local chunk_size_bytes=$((CHUNK_SIZE_MB * 1024 * 1024))
  local search_emoji="🔍"
  local check_emoji="✅"
  local resume_emoji="♻️"
  local warning_emoji="⚠️"

  if [[ -z $(ls "$STATE_DIR"/chunk_*.list 2>/dev/null) ]]; then
    log "$search_emoji Splitting source files into chunks..."
    find "$SOURCE_MOUNT" -type f -printf '%s %p\n' | sort -n > "$STATE_DIR/file_list.txt"
    exec 3< "$STATE_DIR/file_list.txt"
    while read -r size path <&3; do
      if (( current_size + size > chunk_size_bytes )); then
        ((++chunk_index))
        current_size=0
      fi
      echo "$path" >> "$STATE_DIR/chunk_${chunk_index}.list"
      ((current_size += size)) || true
    done
    rm -f "$STATE_DIR/file_list.txt" || true
    log "$check_emoji Created $((chunk_index + 1)) chunk list(s) in $STATE_DIR."
  else
    log "$resume_emoji Resuming previous sync (from $STATE_DIR)."
    log "$warning_emoji Files added or changed on the USB stick after the original listing will NOT be synced."
  fi

}

main() {

  # Remove .done markers if needed
  if $NORESUME; then
    log "⚠️  '--noresume' option specified: removing .done markers (in $DONE_DIR) and chunk lists (in $STATE_DIR)."
    rm -rf "$DONE_DIR" "$STATE_DIR" "$TEMP_DIR"
  fi

  # Setup directories
  [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"
  [[ -d "$DONE_DIR" ]]  || mkdir -p "$DONE_DIR"
  [[ -d "$TEMP_DIR" ]]  || mkdir -p "$TEMP_DIR"

  # Declare main locals
  local \
    start_msg \
    label \
    mount_label \
    direction \
    mount_point_var \
    mount_point \
    chunk_source \
    chunk_target \
    before_mounts

  # Initialze variables
  CHUNKS_GENERATED=false
  CHUNK_COUNT=0
  CURRENT=1

  # Record start time
  START_TIME=$(date +%s)

  while true; do

    # Define chunk index number (based on loop number)
    CHUNK_INDEX=$((CURRENT - 1))

    # Exit loop if all chunks are processed
    # (i.e. when the next one does not exist)
    CHUNK_FILE="${STATE_DIR}/chunk_${CHUNK_INDEX}.list"
    if $CHUNKS_GENERATED && [[ ! -f "$CHUNK_FILE" ]]; then
      if (( CHUNK_INDEX != CHUNK_COUNT )); then
        log "⚠️  Expected $CHUNK_COUNT chunks, but reached missing chunk index $CHUNK_INDEX."
        log "   Possible cause: a chunk list file may have been deleted or renamed."
      else
        log "🎉 All chunks have been synced from USB to SSD!"
      fi
      break
    fi

    # Skip to next chunk if current chunk already done
    DONE_MARKER="${DONE_DIR}/${CHUNK_FILE%.list}.done"
    if [ $NORESUME == false ] && [ -f "$DONE_MARKER" ]; then
      log "⏭️  Skipping $(basename "$CHUNK_FILE") (already done)."
      ((CURRENT++))
      continue
    fi

    # Create temporary directory for syncing
    CHUNK_TEMP_DIR="${TEMP_DIR}/chunk_${CHUNK_INDEX}"
    [ -d "$CHUNK_TEMP_DIR" ] || mkdir -p "$CHUNK_TEMP_DIR"

    # Log start of chunk sync
    start_msg="📦 Starting chunk #$CURRENT"
    [ "$CHUNK_COUNT" -gt 0 ] && start_msg+=" of $CHUNK_COUNT"
    start_msg+=" (using temporary directory ${CHUNK_TEMP_DIR})."
    log "$start_msg"

    # Loop through devices: usb (source), then ssd (destination)
    for device in src dst; do

      # Define device label and mountpoint variable name
      case "$device" in
        src)
          label="USB stick"
          mount_point_var=SOURCE_MOUNT
          ;;
        dst)
          label="SSD"
          mount_point_var=DEST_MOUNT
          ;;
      esac

      # Prompt for device insert and detect mountpoint
      mapfile -t before_mounts < <(ls -1 "/media/$USER" 2>/dev/null)
      prompt_insert_device "$label"
      mount_label=$(detect_newly_mounted_device "$label" "${before_mounts[@]}")
      mount_point="/media/$USER/$mount_label"
      printf -v "$mount_point_var" '%s' "$mount_point"

      # Generate chunk lists based on size (only once, only for source)
      if [ "$device" == "src" ] && [ $CHUNKS_GENERATED == false ]; then
        generate_chunk_lists
        CHUNKS_GENERATED=true
        CHUNK_COUNT=$(find "$STATE_DIR" -maxdepth 1 -type f -name 'chunk_*.list' 2>/dev/null | wc -l)
      fi

      # Define sync direction, chunk source and target
      case "$device" in
        src)
          direction="from"
          chunk_source="$SOURCE_MOUNT"
          chunk_target="$CHUNK_TEMP_DIR"
          ;;
        dst)
          direction="to"
          chunk_source="$CHUNK_TEMP_DIR"
          chunk_target="$DEST_MOUNT"
          ;;
      esac

      # Define rsync options
      RSYNC_OPTS=("--files-from=${CHUNK_FILE}")
      $VERBOSE && RSYNC_OPTS=(-av "${RSYNC_OPTS[@]}") || RSYNC_OPTS=(-ah --progress "${RSYNC_OPTS[@]}")

      # Begin syncing (with possible retry)
      ATTEMPT=1
      while (( ATTEMPT <= MAX_RETRIES )); do
        log "🔁 Attempt $ATTEMPT: Syncing chunk $CURRENT $direction ${label}..."
        if rsync "${RSYNC_OPTS[@]}" "$chunk_source/" "$chunk_target/"; then
          log "✅ Chunk $CURRENT successfully synced $direction ${label}."
          break
        else
          log "⚠️  Rsync failed on attempt $ATTEMPT $direction ${label}."
          ((ATTEMPT++))
          sleep 2
        fi
      done
      if (( ATTEMPT > MAX_RETRIES )); then
        log "❌ Failed to sync chunk $CURRENT $direction $label after $MAX_RETRIES attempts. Aborting."
        exit 1
      fi

      # Unmount and prompt to unplug device 
      safely_unmount_device "$label" "$mount_point"
      prompt_unplug_device "$label"

    done

    # Mark chunk as done and clean up temporary directory
    touch "$DONE_MARKER"
    rm -rf "$CHUNK_TEMP_DIR"

    # Progress and estimate remaining time
    ELAPSED=$(( $(date +%s) - START_TIME ))
    AVG_TIME_PER_CHUNK=$(( ELAPSED / CURRENT ))
    REMAINING_TIME=$(( AVG_TIME_PER_CHUNK * (CHUNK_COUNT - CURRENT) ))
    log "⏱️  Estimated time remaining: $(printf "%02d:%02d" $((REMAINING_TIME/60)) $((REMAINING_TIME%60)))"

    # Next chunk
    ((CURRENT++))

  done

}

main "$@"
exit 0