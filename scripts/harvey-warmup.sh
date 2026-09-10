#!/bin/bash
# Warms the Harvey Ollama model into memory right after boot so the
# first real voice command doesn't pay a 30s-2min cold-load penalty.
TOKEN=$(cat /opt/harvey/ha_token)

# Load the LOCAL model directly, before touching Home Assistant. This is the
# offline path, so it has to be warmed even when the bus has no network at all
# and the remote Mac backend is unreachable. keep_alive -1 pins it in memory.
curl -sf --max-time 300 http://localhost:11434/api/chat \
    -H "Content-Type: application/json" \
    -d '{"model":"harvey:latest","keep_alive":-1,"stream":false,
         "messages":[{"role":"user","content":"warmup"}]}' \
    >> /opt/harvey/logs/warmup.log 2>&1
echo "$(date): local model warmed" >> /opt/harvey/logs/warmup.log

# Wait for HA API to be reachable (up to 3 minutes)
for i in $(seq 1 36); do
    if curl -sf http://localhost:8123/api/ -H "Authorization: Bearer $TOKEN" >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

# Warm Home Assistant's own conversation path against the local agent — the
# remote one may be asleep or off-network, and warming it would just hang.
curl -s -X POST http://localhost:8123/api/conversation/process \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"text":"warmup","agent_id":"conversation.harvey"}' >> /opt/harvey/logs/warmup.log 2>&1
echo "$(date): warmup call sent" >> /opt/harvey/logs/warmup.log
