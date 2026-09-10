#!/bin/bash
# Harvey Satellite launcher — auto-detects a USB mic (e.g. webcam) for
# capture and uses the onboard Dell audio (PCH/ALC3234) for playback.
# Exits non-zero if no non-onboard capture device is found yet; systemd
# (Restart=always) will retry every 10s, so plugging in a mic "just works"
# without needing a manual restart.
#
# Mic is muted while TTS is speaking to prevent Harvey's own voice
# (played through the speaker) from being picked up by the mic and
# spuriously re-triggering the wake word / garbling the next command.
set -euo pipefail

MIC_CARD_INDEX=$(arecord -l | awk '/^card/ && $0 !~ /PCH/ {gsub(":", "", $2); print $2; exit}')

if [[ -z "$MIC_CARD_INDEX" ]]; then
    echo "No non-onboard capture device found yet (plug in the mic/webcam) — will retry."
    exit 1
fi

echo "Using capture card index: $MIC_CARD_INDEX"

exec /opt/harvey/venv-satellite/bin/python3 -m wyoming_satellite \
    --name "Harvey Satellite" \
    --uri "tcp://0.0.0.0:10700" \
    --mic-command "arecord -D plughw:${MIC_CARD_INDEX},0 -r 16000 -c 1 -f S16_LE -t raw" \
    --mic-command-rate 16000 \
    --mic-auto-gain 31 \
    --mic-noise-suppression 1 \
    --snd-command "aplay -D plughw:CARD=PCH,DEV=0 -r 22050 -c 1 -f S16_LE -t raw" \
    --snd-command-rate 22050 \
    --wake-uri "tcp://localhost:10400" \
    --wake-word-name "hey_harvey" \
    --no-zeroconf \
    --error-command "bash -c 'amixer -c ${MIC_CARD_INDEX} sset Mic nocap; aplay -D plughw:CARD=PCH,DEV=0 /opt/harvey/sounds/error_didnt_catch.wav; sleep 1; amixer -c ${MIC_CARD_INDEX} sset Mic cap'" \
    --tts-start-command "amixer -c ${MIC_CARD_INDEX} sset Mic nocap" \
    --tts-stop-command "bash -c 'sleep 4; amixer -c ${MIC_CARD_INDEX} sset Mic cap'" \
    --debug
