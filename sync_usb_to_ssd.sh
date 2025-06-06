#!/usr/bin/env bash

set -euo pipefail

# ======== CONFIGURATION ========
CHUNK_SIZE_MB=3500
MAX_RETRIES=2
TEMP_DIR="$HOME/usb_temp"
LIST_DIR="$HOME/.usb_sync_chunks"
# ===============================

# ========== Functions ==========

print_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --noresume       Ignore previous state and re-copy all chunks
  --verify         Perform final verification after sync (can be slow)
  --quiet          Suppress most output
  --verbose        Print all rsync output (default is progress only)
  --help           Show this help message and exit
EOF
  exit 0
}

log() {
  if [[ $QUIET == false ]]; then
    echo -e "$@"
  fi
}

wait_for_new_mount() {
  local before=("$@")
  log "🔌 Waiting for a new device to be mounted..."
  while true; do
    sleep 1
    local after=($(ls "/media/$USER" 2>/dev/null))
    for item in "${after[@]}"; do
      if [[ ! " ${before[*]} " =~ " $item " ]]; then
        echo "$item"
        return
      fi
    done
  done
}

clear_temp_dir() {
  rm -rf "$TEMP_DIR"
  mkdir -p "$TEMP_DIR"
}

format_time() {
  local seconds=$1
  printf "%02d:%02d
" $((seconds / 60)) $((seconds % 60))
}

# ======= Options Parsing =======
NORESUME=false
VERIFY=false
QUIET=false
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --noresume) NORESUME=true ;;
    --verify) VERIFY=true ;;
    --quiet) QUIET=true ;;
    --verbose) VERBOSE=true ;;
    --help) print_help ;;
    *) echo "Unknown option: $arg" && print_help ;;
  esac
done

# ============ Setup ============
mkdir -p "$TEMP_DIR" "$LIST_DIR"
if $NORESUME; then
  log "⚠️  '--noresume' specified: removing .done markers in $LIST_DIR"
  rm -f "$LIST_DIR"/chunk_*.done
fi

# ========== Detect USB =========
log "📥 Please plug in the USB stick and press Enter."
read -r
before_mounts=($(ls "/media/$USER" 2>/dev/null))
SOURCE_LABEL=$(wait_for_new_mount "${before_mounts[@]}")
SOURCE_MOUNT="/media/$USER/$SOURCE_LABEL"
log "✅ USB detected as: $SOURCE_LABEL"

# === Create Size-Based Chunks ===
log "🔍 Building file list with sizes from $SOURCE_MOUNT..."
find "$SOURCE_MOUNT" -type f -printf "%p	%s\n" > "$LIST_DIR/full_list_with_sizes.txt"
log "🔢 Splitting into chunks of approx ${CHUNK_SIZE_MB} MiB..."
awk -v limit=$((CHUNK_SIZE_MB * 1024 * 1024)) -v list_dir="$LIST_DIR" '
BEGIN {
  chunk = 0;
  size = 0;
  outfile = sprintf("%s/chunk_%03d", list_dir, chunk);
}
{
  if (size + $2 > limit) {
    chunk++;
    size = 0;
    outfile = sprintf("%s/chunk_%03d", list_dir, chunk);
  }
  print $1 >> outfile;
  size += $2;
}
' "$LIST_DIR/full_list_with_sizes.txt"
CHUNK_FILES=("$LIST_DIR"/chunk_*)
CHUNK_COUNT=${#CHUNK_FILES[@]}
CURRENT=1
START_TIME=$(date +%s)

# ========== Sync Loop ==========
for chunk_file in "${CHUNK_FILES[@]}"; do
  done_marker="${chunk_file}.done"

  if [[ -f "$done_marker" ]]; then
    log "⏭️  Skipping chunk $(basename "$chunk_file") — already marked done."
    ((CURRENT++))
    continue
  fi

  ATTEMPT=1
  while (( ATTEMPT <= MAX_RETRIES )); do
    log ""
    log "[$CURRENT/$CHUNK_COUNT] Processing chunk: $(basename "$chunk_file") (Attempt $ATTEMPT of $MAX_RETRIES)"

    log "📥 Plug in the USB stick again and press Enter."
    read -r
    before_mounts=($(ls "/media/$USER" 2>/dev/null))
    SOURCE_LABEL=$(wait_for_new_mount "${before_mounts[@]}")
    SOURCE_MOUNT="/media/$USER/$SOURCE_LABEL"
    log "✅ USB mounted as $SOURCE_LABEL"

    clear_temp_dir
    log "📤 Copying chunk from USB to temp dir..."
    if $VERBOSE; then
      rsync -av --files-from="$chunk_file" --from0 < <(tr '
' ' ' < "$chunk_file") "$SOURCE_MOUNT/" "$TEMP_DIR/" || { log "❌ rsync from USB failed."; ((ATTEMPT++)); continue; }
    else
      rsync -ah --progress --files-from="$chunk_file" --from0 < <(tr '
' ' ' < "$chunk_file") "$SOURCE_MOUNT/" "$TEMP_DIR/" || { log "❌ rsync from USB failed."; ((ATTEMPT++)); continue; }
    fi

    log "🔌 Unmounting USB stick ($SOURCE_LABEL)..."
    udisksctl unmount -b "$(lsblk -no PKNAME "$(findmnt -no SOURCE "$SOURCE_MOUNT")")" >/dev/null 2>&1 || true
    udisksctl power-off -b "$(lsblk -no PKNAME "$(findmnt -no SOURCE "$SOURCE_MOUNT")")" >/dev/null 2>&1 || true
    log "✅ USB stick unmounted. It is now safe to unplug it."
    read -r -p "Please unplug USB stick and plug in SSD, then press Enter to continue."
    before_mounts=($(ls "/media/$USER" 2>/dev/null))
    DEST_LABEL=$(wait_for_new_mount "${before_mounts[@]}")
    DEST_MOUNT="/media/$USER/$DEST_LABEL"
    log "✅ SSD mounted as $DEST_LABEL"

    log "💾 Copying chunk to SSD..."
    if $VERBOSE; then
      rsync -av "$TEMP_DIR/" "$DEST_MOUNT/" || { log "❌ rsync to SSD failed."; ((ATTEMPT++)); continue; }
    else
      rsync -ah --progress "$TEMP_DIR/" "$DEST_MOUNT/" || { log "❌ rsync to SSD failed."; ((ATTEMPT++)); continue; }
    fi

    touch "$done_marker"
    clear_temp_dir
    log "✅ Chunk $CURRENT copied and marked done."

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    AVG_TIME=$((ELAPSED / CURRENT))
    REMAINING=$(((CHUNK_COUNT - CURRENT) * AVG_TIME))
    log "⏱️  Estimated time remaining: $(format_time $REMAINING)"

    break
  done

  if (( ATTEMPT > MAX_RETRIES )); then
    log "❌ Failed to copy chunk $(basename "$chunk_file") after $MAX_RETRIES attempts. Exiting."
    exit 1
  fi

  ((CURRENT++))
done

# ==== Optional Verification ====
if $VERIFY; then
  log "🔍 Starting final verification..."
  log "📥 Plug in the USB stick and press Enter."
  read -r
  before_mounts=($(ls "/media/$USER" 2>/dev/null))
  SOURCE_LABEL=$(wait_for_new_mount "${before_mounts[@]}")
  SOURCE_MOUNT="/media/$USER/$SOURCE_LABEL"
  log "✅ USB mounted as $SOURCE_LABEL"

  log "🔌 Unmounting SSD ($DEST_LABEL)..."
  udisksctl unmount -b "$(lsblk -no PKNAME "$(findmnt -no SOURCE "$DEST_MOUNT")")" >/dev/null 2>&1 || true
  udisksctl power-off -b "$(lsblk -no PKNAME "$(findmnt -no SOURCE "$DEST_MOUNT")")" >/dev/null 2>&1 || true
  log "✅ SSD unmounted. It is now safe to unplug it."
  read -r -p "Please unplug SSD and press Enter to continue."
  before_mounts=($(ls "/media/$USER" 2>/dev/null))
  DEST_LABEL=$(wait_for_new_mount "${before_mounts[@]}")
  DEST_MOUNT="/media/$USER/$DEST_LABEL"
  log "✅ SSD mounted as $DEST_LABEL"

  log "🔄 Running recursive diff (may take a while)..."
  diff -rq "$SOURCE_MOUNT" "$DEST_MOUNT" || log "⚠️  Differences found!"
  log "✅ Verification complete."
fi

log "🎉 All chunks have been synced from USB to SSD!"
exit 0
