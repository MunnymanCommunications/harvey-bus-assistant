# 🚌 HARVEY BUS ASSISTANT v3 — Complete Auto-Deploy
## Venture LLC | MunnymanCommunications

> **Goal:** One command. Server powers on. Harvey is ready. No browser wizard. Survives any power outage.

---

## What Happens When You Run `install.sh`

```
You type: sudo bash install.sh
You answer 4 questions (username, password, timezone, Gemini key)
You wait 15-20 minutes

Result: Harvey is LIVE, auto-starts on every boot, auto-recovers from power cuts.
```

**No browser wizard. No clicking around. Just works.**

---

## The 4 Questions It Asks

1. **Username** — your HA login (e.g. `catalina`)
2. **Password** — your HA password
3. **Timezone** — e.g. `America/Denver` (or Enter for default)
4. **Gemini API key** — optional, for cloud fallback when online

That's it. Everything else is automatic.

---

## After Install — 3 Quick Steps (takes ~5 min total)

### Step 1 — BIOS Power Setting (do this once, prevents needing someone home after outage)

Reboot the Dell server → press **F2** or **Del** to enter BIOS → find:

```
Power Management → AC Power Recovery → Set to "Power On"
  (also called: Restore on AC Power Loss, After Power Loss, AC Back)
```

Save and exit. Now the server always boots when power returns.

> **Note:** The install script tries to set this via IPMI automatically. If it worked, skip this step.

### Step 2 — Add Wyoming Voice Integrations (2 min)

Open `http://SERVER-IP:8123` → **Settings → Devices & Services → + Add Integration**

Add these 3 in order:
1. **Wyoming Protocol** → Host: `localhost`, Port: `10300` (Whisper STT)
2. **Wyoming Protocol** → Host: `localhost`, Port: `10200` (Piper TTS)
3. **Wyoming Protocol** → Host: `localhost`, Port: `10400` (OpenWakeWord)

Then run the auto-config script for faster setup:
```bash
sudo bash scripts/configure-voice.sh
```

### Step 3 — Add Kamtron Camera

**Settings → Integrations → + Add → search "ONVIF"**

Or use Generic Camera with your RTSP URL:
```
rtsp://admin:PASSWORD@YOUR_CAMERA_IP:554/stream1
```

---

## Power Outage Recovery — How It Works

| Layer | What Handles It |
|-------|----------------|
| **Hardware boot** | BIOS "Restore on AC Power Loss = Power On" |
| **OS services** | systemd `After=network-online.target` ordering |
| **Docker containers** | `restart: always` on every container |
| **Harvey stack** | `harvey-stack.service` (enabled, auto-starts) |
| **Ollama LLM** | `ollama.service` (enabled, auto-starts) |
| **Watchdog** | `harvey-watchdog.timer` (checks every 2 min, restarts anything dead) |

**Full recovery time after power outage: ~90 seconds**

---

## Architecture

```
POWER RESTORED
     │
     ▼ (BIOS auto-boots)
Ubuntu boots → systemd starts:
  ├── docker.service
  ├── ollama.service        ← Qwen2.5-1.5B LLM
  ├── harvey-stack.service  ← HA + Whisper + Piper + WakeWord
  └── harvey-watchdog.timer ← health monitor

     │
     ▼ (~90 seconds)
HOME ASSISTANT LIVE at :8123

     │
     ▼
You say: "Hey Jarvis"
     │
     ▼ (OpenWakeWord, Coral-accelerated)
Whisper STT transcribes your voice
     │
     ▼ (Harvey Router)
     ├── Simple command → HA directly (<200ms)
     └── Complex query → Qwen2.5-1.5B via Ollama
     │
     ▼
Piper TTS speaks Harvey's response
```

---

## File Locations

```
/opt/harvey/
├── docker-compose.yml      ← All containers
├── ha-config/              ← Home Assistant config (pre-provisioned)
│   ├── configuration.yaml
│   ├── secrets.yaml        ← API keys (chmod 600)
│   ├── automations.yaml
│   ├── packages/           ← Split config files
│   │   ├── harvey_voice.yaml
│   │   └── harvey_scenes.yaml
│   └── .storage/           ← HA internal state (pre-seeded)
│       ├── onboarding      ← Skips wizard
│       ├── auth            ← Your user account
│       └── auth_provider.* ← Bcrypt password hash
├── whisper-data/           ← Whisper models cache
├── piper-data/             ← Piper voice models
├── models/                 ← Coral TFLite models
├── scripts/
│   ├── install.sh          ← Master installer
│   ├── configure-voice.sh  ← Voice auto-config
│   ├── harvey_router.py    ← Intent router
│   └── watchdog.sh         ← Health monitor
├── logs/                   ← Service logs
├── ha_token                ← HA long-lived token (chmod 600)
└── Modelfile.harvey        ← Harvey AI personality
```

---

## Useful Commands

```bash
# Check everything is running
docker ps

# Watch logs live
docker logs homeassistant -f
docker logs whisper-stt -f

# Restart everything
sudo systemctl restart harvey-stack

# Test Harvey AI directly
ollama run harvey "Turn on the lights"

# Check watchdog is running
systemctl status harvey-watchdog.timer

# Check Coral TPU
lsusb | grep -i "google\|coral"
python3 -c "from pycoral.utils.edgetpu import list_edge_tpus; print(list_edge_tpus())"

# View system health
htop   # RAM usage
df -h  # Disk usage
free -h  # Swap status
```

---

## RAM Budget on 4GB

```
Home Assistant:          ~800MB
Whisper (tiny-int8):     ~300MB
Piper TTS:               ~150MB
OpenWakeWord:            ~100MB
Qwen2.5-1.5B (Ollama):  ~1.1GB  (loads on first query)
OS + Docker overhead:    ~400MB
────────────────────────────────
Total:                   ~2.85GB  ✅ fits with room to spare
Swap (buffer):           4GB      ✅ never needed in normal use
```

---

## Troubleshooting

**HA not loading after install:**
```bash
docker logs homeassistant --tail 50
# If you see auth errors, delete .storage and re-run install
```

**Voice not working:**
```bash
docker logs whisper-stt -f   # Check Whisper
nc -z localhost 10300 && echo "Whisper OK"
nc -z localhost 10200 && echo "Piper OK"
```

**Coral not detected:**
```bash
lsusb   # Should show Google / 1a6e
ls /dev/bus/usb/
```

**After power outage — checking recovery:**
```bash
systemctl status harvey-stack
docker ps
curl http://localhost:8123/api/  # Should return {"message":"API running."}
```

---

*Harvey Bus Assistant v3 | Venture LLC | MunnymanCommunications*
*Built June 2026*
