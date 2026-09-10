#!/bin/bash
# Watches for a custom openWakeWord model to appear in the user's download
# locations and, once one does, installs it as Harvey's wake word.
#
# Written to run unattended from a timer, so it is deliberately cautious: the
# model is proven to load before anything is switched over, and any failure
# rolls back to the previous wake word rather than leaving the bus with an
# assistant that cannot hear. On success the timer disables itself.
set -uo pipefail

LOG=/opt/harvey/logs/wakeword-install.log
MODEL_DIR=/opt/harvey/openwakeword-models
SAT=/opt/harvey/scripts/start-satellite.sh
SEARCH_DIRS=(/home/royl/Downloads /home/royl/Desktop /home/royl)
CONTAINER=openwakeword

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Only consider models the user actually meant as a Harvey wake word.
found=""
for d in "${SEARCH_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
        [[ -n "$f" ]] && found="$f" && break 2
    done < <(find "$d" -maxdepth 1 -type f -iname "*harvey*.tflite" 2>/dev/null | sort)
done

if [[ -z "$found" ]]; then
    # Flag the case where training produced only an ONNX file, which this
    # script cannot convert — that needs the conversion toolchain.
    for d in "${SEARCH_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        onnx=$(find "$d" -maxdepth 1 -type f -iname "*harvey*.onnx" 2>/dev/null | head -1)
        if [[ -n "$onnx" ]]; then
            log "found ONNX only ($onnx) — needs conversion to .tflite, leaving for manual handling"
            exit 0
        fi
    done
    exit 0
fi

# Chrome appends " (1)" and similar to repeat downloads; the filename becomes
# the wake word id, so it has to be clean.
base=$(basename "$found" .tflite)
name=$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/ *\([0-9]+\)$//; s/[^a-z0-9]+/_/g; s/^_+|_+$//g')
[[ -z "$name" ]] && name="hey_harvey"

log "found model: $found -> installing as '$name'"

prev_word=$(grep -oP '(?<=--wake-word-name ")[^"]+' "$SAT" | head -1)
[[ -z "$prev_word" ]] && prev_word="hey_jarvis"

install -o root -g root -m 644 "$found" "$MODEL_DIR/$name.tflite" || { log "copy failed"; exit 1; }

docker restart "$CONTAINER" >/dev/null 2>&1
sleep 10

# Prove the model actually loads before pointing the satellite at it. A model
# that merely appears in the directory listing can still fail at load time.
if ! docker exec "$CONTAINER" /usr/src/.venv/bin/python3 -c "
from pyopen_wakeword.openwakeword import OpenWakeWord
OpenWakeWord.from_model('/custom-models/$name.tflite')
" >/dev/null 2>&1; then
    log "ERROR: '$name' failed to load — removing it and keeping '$prev_word'"
    rm -f "$MODEL_DIR/$name.tflite"
    docker restart "$CONTAINER" >/dev/null 2>&1
    exit 1
fi
log "model loads cleanly"

cp "$SAT" "$SAT.bak-wakeword"
sed -i "s/--wake-word-name \"[^\"]*\"/--wake-word-name \"$name\"/" "$SAT"
systemctl restart harvey-satellite.service
sleep 12

if systemctl is-active --quiet harvey-satellite.service && \
   grep -q "Connected to wake service" <(tail -30 /opt/harvey/logs/satellite.log); then
    log "SUCCESS: wake word is now '$name' (was '$prev_word')"
    mv "$found" "$found.installed"
    systemctl disable --now harvey-wakeword-install.timer >/dev/null 2>&1
    log "timer disabled — nothing further to do"
else
    log "ERROR: satellite unhealthy after switch — rolling back to '$prev_word'"
    mv "$SAT.bak-wakeword" "$SAT"
    rm -f "$MODEL_DIR/$name.tflite"
    docker restart "$CONTAINER" >/dev/null 2>&1
    systemctl restart harvey-satellite.service
    log "rolled back"
    exit 1
fi
