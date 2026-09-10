#!/bin/bash
# Restarts the satellite to clear stuck Wyoming connections -- but only when
# it's actually idle. Restarting while it's speaking tears out the TCP writer
# HA is mid-stream on, which crashes with:
#   AssertionError in wyoming/client.py write_event: self._writer is not None
# and cuts Harvey off mid-word. Confirmed twice (2026-09-07 15:47, 2026-09-09
# 21:43) exactly matching this timer's fire time.
TOKEN=$(cat /opt/harvey/ha_token)
STATE=$(curl -sf --max-time 5 http://localhost:8123/api/states/assist_satellite.harvey_satellite \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)

if [[ "$STATE" != "idle" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] satellite is '$STATE', not idle -- deferring refresh 2 minutes" >> /opt/harvey/logs/watchdog.log
    systemd-run --on-active=2min --unit=harvey-satellite-refresh-retry -- /opt/harvey/scripts/satellite-refresh.sh
    exit 0
fi

systemctl restart harvey-satellite.service
