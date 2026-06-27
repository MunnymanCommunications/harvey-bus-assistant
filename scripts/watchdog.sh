#!/bin/bash
# Harvey Watchdog — checks and restarts failed services every 2 min
# Installed as a systemd timer: harvey-watchdog.timer

LOG=/opt/harvey/logs/watchdog.log
DATE=$(date '+%Y-%m-%d %H:%M:%S')

check_service() {
    local name="$1"
    if ! systemctl is-active --quiet "$name"; then
        echo "[$DATE] WARNING: $name not active — restarting" >> "$LOG"
        systemctl start "$name"
    fi
}

check_container() {
    local name="$1"
    if ! docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
        echo "[$DATE] WARNING: container $name not running — restarting" >> "$LOG"
        cd /opt/harvey && docker compose up -d "$name"
    fi
}

check_service "ollama"
check_service "harvey-stack"
check_container "homeassistant"
check_container "whisper-stt"
check_container "piper-tts"
check_container "openwakeword"

# Log heartbeat every hour
if [[ $(date +%M) == "00" ]]; then
    echo "[$DATE] Heartbeat — all checks passed" >> "$LOG"
fi
