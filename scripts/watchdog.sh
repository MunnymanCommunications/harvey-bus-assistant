#!/bin/bash
# Harvey Watchdog — checks and restarts failed services
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
        echo "[$DATE] WARNING: container $name not running — restarting stack" >> "$LOG"
        cd /opt/harvey && docker compose up -d "$name"
    fi
}

# Detect the satellite's known "stuck listening/processing" bug: the
# assist_satellite entity gets wedged in a non-idle state and silently
# stops responding to new wake words, even though the process itself
# still shows as "active". A plain is-active check can't catch this.
check_satellite_stuck() {
    local token state last_changed last_epoch now_epoch age
    token=$(cat /opt/harvey/ha_token 2>/dev/null)
    [[ -z "$token" ]] && return

    local resp
    resp=$(curl -sf --max-time 5 http://localhost:8123/api/states/assist_satellite.harvey_satellite \
        -H "Authorization: Bearer ${token}" 2>/dev/null)
    [[ -z "$resp" ]] && return

    state=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
    last_changed=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_changed',''))" 2>/dev/null)
    [[ -z "$state" || -z "$last_changed" ]] && return

    if [[ "$state" == "idle" ]]; then
        return
    fi

    last_epoch=$(date -d "$last_changed" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    [[ -z "$last_epoch" ]] && return
    age=$(( now_epoch - last_epoch ))

    # How long a state can legitimately last differs enormously, so a single
    # threshold either kills real work or leaves a wedge sitting too long.
    #   listening  — bounded by VAD, so past ~45s it is always a wedge.
    #   processing — STT plus generation; on this CPU a long answer can take
    #                a minute, and prompt evaluation alone has hit 25s.
    #   responding — the reply is being spoken. num_predict allows 250 tokens,
    #                which is around 90s of speech, so this needs the most room.
    local limit
    case "$state" in
        listening)  limit=45  ;;
        processing) limit=120 ;;
        responding) limit=180 ;;
        *)          limit=45  ;;
    esac

    if (( age > limit )); then
        echo "[$DATE] WARNING: satellite stuck in '$state' for ${age}s (limit ${limit}s) — restarting" >> "$LOG"
        systemctl restart harvey-satellite.service

        # Restarting the satellite alone does not always clear it: if the
        # entity state is wedged on the Home Assistant side, the integration
        # only pushes a new state on a transition, so it stays stuck. Reload
        # the Wyoming config entry to force the entity back to a clean state.
        sleep 8
        state=$(curl -sf --max-time 5 http://localhost:8123/api/states/assist_satellite.harvey_satellite \
            -H "Authorization: Bearer ${token}" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
        if [[ "$state" != "idle" ]]; then
            # Resolved fresh each time (not hardcoded): this is the config
            # entry ID of whichever Wyoming integration owns the satellite
            # entity, which differs per install and can even change on this
            # one if the integration is ever removed and re-added.
            local wyoming_entry_id
            wyoming_entry_id=$(python3 -c "
import json
reg = json.load(open('/opt/harvey/ha-config/.storage/core.entity_registry'))
ent = next((e for e in reg['data']['entities']
            if e['entity_id'] == 'assist_satellite.harvey_satellite'), None)
print(ent['config_entry_id'] if ent else '')
" 2>/dev/null)
            if [[ -n "$wyoming_entry_id" ]]; then
                echo "[$DATE] Still '$state' after restart — reloading Wyoming integration ($wyoming_entry_id)" >> "$LOG"
                curl -sf --max-time 10 -X POST \
                    "http://localhost:8123/api/config/config_entries/entry/${wyoming_entry_id}/reload" \
                    -H "Authorization: Bearer ${token}" >/dev/null 2>&1
            else
                echo "[$DATE] Still '$state' after restart — could not resolve Wyoming entry to reload" >> "$LOG"
            fi
        fi
    fi
}

check_service "ollama"
check_service "harvey-stack"
check_service "harvey-satellite"
check_container "homeassistant"
check_container "whisper-stt"
check_container "piper-tts"
check_container "openwakeword"
check_satellite_stuck
