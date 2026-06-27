#!/bin/bash
# =================================================================
#  HARVEY — Wyoming Voice Auto-Config
#  Run this once after Home Assistant is fully started.
#  Configures Whisper STT, Piper TTS, OpenWakeWord, Ollama, 
#  and creates the Harvey voice assistant pipeline — all via API.
# =================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[!]${NC}   $1"; }

HA_URL="${HA_URL:-http://localhost:8123}"
HA_TOKEN="${HA_TOKEN:-$(cat /opt/harvey/ha_token 2>/dev/null)}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

[[ -z "$HA_TOKEN" ]] && { echo "Set HA_TOKEN or run from install script"; exit 1; }

# Helper — HA REST API call
ha() {
    local method="$1" path="$2" data="${3:-}"
    if [[ -n "$data" ]]; then
        curl -sf -X "$method" "${HA_URL}${path}" \
            -H "Authorization: Bearer ${HA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -sf -X "$method" "${HA_URL}${path}" \
            -H "Authorization: Bearer ${HA_TOKEN}"
    fi
}

# ── Wait for HA ────────────────────────────────────────────────
info "Waiting for Home Assistant API..."
for i in $(seq 1 30); do
    if ha GET /api/ 2>/dev/null | grep -q "ok\|message"; then
        success "HA API responding"
        break
    fi
    sleep 5
    printf "  %d/30...\r" "$i"
done

# ── Check Wyoming services are up ─────────────────────────────
info "Checking Wyoming services..."
for port in 10300 10200 10400; do
    if nc -z localhost "$port" 2>/dev/null; then
        success "Port $port is open"
    else
        warn "Port $port not yet open — services may still be downloading models"
    fi
done

# ── Add Wyoming Integrations via Config Flow ──────────────────
info "Configuring Wyoming integrations..."

add_wyoming() {
    local name="$1" host="$2" port="$3"
    info "Adding Wyoming: $name ($host:$port)..."

    # Step 1: Init the flow
    local flow_resp
    flow_resp=$(ha POST /api/config/config_entries/flow \
        '{"handler":"wyoming","show_advanced_options":false}' 2>/dev/null || echo '{}')
    local flow_id
    flow_id=$(echo "$flow_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('flow_id',''))" 2>/dev/null || echo "")

    if [[ -z "$flow_id" ]]; then
        warn "Could not init Wyoming flow for $name — add manually in HA UI"
        return
    fi

    # Step 2: Submit host/port
    local result
    result=$(ha POST "/api/config/config_entries/flow/${flow_id}" \
        "{\"host\":\"${host}\",\"port\":${port}}" 2>/dev/null || echo '{}')

    if echo "$result" | grep -q '"result"\|"type":"create_entry"'; then
        success "Wyoming $name integration added!"
    else
        warn "Wyoming $name — check HA UI to confirm (Settings → Integrations)"
    fi
}

add_wyoming "Whisper STT"   "localhost" "10300"
sleep 2
add_wyoming "Piper TTS"     "localhost" "10200"
sleep 2
add_wyoming "OpenWakeWord"  "localhost" "10400"
sleep 2

# ── Add Ollama Integration ────────────────────────────────────
info "Adding Ollama integration..."
ollama_flow=$(ha POST /api/config/config_entries/flow \
    '{"handler":"ollama","show_advanced_options":false}' 2>/dev/null || echo '{}')
ollama_flow_id=$(echo "$ollama_flow" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('flow_id',''))" 2>/dev/null || echo "")

if [[ -n "$ollama_flow_id" ]]; then
    ha POST "/api/config/config_entries/flow/${ollama_flow_id}" \
        "{\"url\":\"${OLLAMA_URL}\"}" 2>/dev/null || true
    sleep 2
    # Select model
    ollama_flow2=$(ha POST "/api/config/config_entries/flow/${ollama_flow_id}" \
        '{"model":"harvey"}' 2>/dev/null || echo '{}')
    if echo "$ollama_flow2" | grep -q '"result"\|"type":"create_entry"'; then
        success "Ollama integration added with harvey model!"
    else
        warn "Ollama — verify in HA UI (Settings → Integrations → Ollama)"
    fi
else
    warn "Could not add Ollama via API — add manually in HA UI"
fi

# ── Create Harvey Voice Pipeline via HA Websocket API ─────────
info "Creating Harvey voice pipeline..."

# Use Python for websocket since curl doesn't do WS
python3 << PYEOF
import asyncio, json, sys, os

# Try to use websocket
try:
    import websockets
except ImportError:
    print("  [!] websockets not installed — skipping pipeline creation")
    print("      Create manually: Settings → Voice Assistants → Add Assistant")
    sys.exit(0)

HA_URL = os.environ.get("HA_URL", "http://localhost:8123")
HA_TOKEN = os.environ.get("HA_TOKEN", "")
WS_URL = HA_URL.replace("http://", "ws://").replace("https://", "wss://") + "/api/websocket"

async def create_pipeline():
    try:
        async with websockets.connect(WS_URL, open_timeout=10) as ws:
            # Auth
            await ws.send(json.dumps({"type": "auth", "access_token": HA_TOKEN}))
            auth_resp = json.loads(await ws.recv())
            if auth_resp.get("type") != "auth_ok":
                print("  [!] WebSocket auth failed")
                return

            # List existing pipelines
            await ws.send(json.dumps({"id": 1, "type": "assist_pipeline/pipeline/list"}))
            pipelines = json.loads(await ws.recv())

            # Create Harvey pipeline
            await ws.send(json.dumps({
                "id": 2,
                "type": "assist_pipeline/pipeline/create",
                "conversation_engine": "conversation.ollama",
                "language": "en-US",
                "name": "Harvey",
                "stt_engine": "stt.whisper",
                "stt_language": "en",
                "tts_engine": "tts.piper",
                "tts_language": "en-US",
                "tts_voice": "en_US-ryan-medium",
                "wake_word_entity_id": "wake_word.openWakeWord"
            }))
            resp = json.loads(await ws.recv())
            if resp.get("success"):
                print("  [✓] Harvey voice pipeline created!")
            else:
                print(f"  [!] Pipeline creation: {resp}")
    except Exception as e:
        print(f"  [!] WebSocket: {e} — create pipeline manually in HA UI")

asyncio.run(create_pipeline())
PYEOF

echo ""
success "Wyoming auto-config complete!"
echo ""
echo "  If anything shows [!], complete in HA UI:"
echo "  http://$(hostname -I | awk '{print $1}'):8123"
echo "  Settings → Voice Assistants → Add Assistant → Harvey"
echo ""
