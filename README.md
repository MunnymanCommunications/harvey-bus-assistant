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

### Step 2b — Voice Satellite (manual, hardware-specific)

`install.sh` sets up Harvey's "brain" (HA, Whisper, Piper, OpenWakeWord,
Ollama) fully automatically, but it does **not** auto-detect this machine's
mic and speaker — that's the one step that's genuinely different on every
box. Once your USB mic/webcam and speakers are connected:

```bash
sudo cp scripts/start-satellite.sh /opt/harvey/scripts/
sudo cp systemd/harvey-satellite.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now harvey-satellite.service
```

`start-satellite.sh` auto-picks the first non-onboard capture card (so
plugging in a different USB mic just works without editing anything) and
plays back through the onboard analog output — edit the `snd-command` in
that script if your speakers are elsewhere (HDMI, a USB DAC, etc).

A desktop shortcut for `scripts/monitor.py` (live transcript/response/error
view) is at `desktop/harvey-monitor.desktop` — copy it to `~/Desktop/` and
mark it executable/trusted from your file manager.

Once the satellite is up, enable the timers that depend on it:
```bash
sudo systemctl enable --now harvey-satellite-refresh.timer   # hourly connection refresh
sudo systemctl enable --now harvey-wakeword-install.timer    # auto-installs a custom wake word if you train one
sudo systemctl enable --now harvey-warmup.service             # preloads the model on boot
```

### Step 3 — Add Kamtron Camera

**Settings → Integrations → + Add → search "ONVIF"**

Or use Generic Camera with your RTSP URL:
```
rtsp://admin:PASSWORD@YOUR_CAMERA_IP:554/stream1
```

---

## Custom Wake Word

`hey_harvey.tflite` in `ha-config/openwakeword-models/` is a trained
openWakeWord model, done via the free Colab notebook in
[dscripka/openWakeWord](https://github.com/dscripka/openWakeWord)
(`notebooks/automatic_model_training.ipynb`). Its recall isn't as high as
the stock `hey_jarvis` model — expect to repeat yourself more often — so
train a longer/higher-setting run (`n_samples: 10000`, `steps: 50000`)
before relying on it daily.

To switch to it (or install a wake word you train yourself), the easiest
path is automatic: drop a `*harvey*.tflite` file anywhere in the Dell's home
folder or Downloads and `harvey-wakeword-install.timer` (checks every 2
hours) finds it, verifies it actually loads before touching anything, and
switches the satellite over — rolling back to the previous wake word if
the new model fails to load. See `scripts/install-wakeword.sh`.

If your model is only `.onnx` (Colab's TFLite export step can fail), convert
it locally: `python3 scripts/oww_onnx_to_tflite.py model.onnx model.tflite`
— this rebuilds the small classifier network directly in Keras rather than
relying on `onnx_tf`/`onnx2tf`, both of which either fail outright or
silently mis-transpose the input shape for this specific model family.

---

## Reminders & Timers

Timers and reminders are handled **deterministically** — via Home
Assistant's own sentence-matching engine, never by asking the 1.5B model to
call a function — because a model that small will occasionally claim to
have set a timer it never actually created. See `ha-config/packages/harvey_reminders.yaml`.

- Reminders live in a real `local_todo` list, announced on a repeating
  hourly nag until you say "mark that complete" — which always resolves to
  whichever reminder was just spoken, tracked in a helper set only at the
  moment of speaking.
- Real reminder state is injected into the LLM's system prompt every turn
  (the same mechanism Home Assistant uses to inject the current date/time),
  so free-form questions like "what's on my plate today" get a grounded
  answer instead of a guess.
- `ha-config/custom_sentences/en/harvey_timer_tolerance.yaml` extends the
  built-in timer intents to tolerate common Whisper mis-transcriptions
  (e.g. "set **of** timer" heard instead of "set **a** timer"); extend this
  file with real STT misses as you find them rather than fighting the model.

---

## Running the Brain Remotely (LLM Failover)

The Ollama conversation agent can point at a **remote** host (e.g. a second
Mac on the LAN running its own Ollama, for a bigger/faster model) alongside
the local one, with automatic failover baked in: `harvey-llm-failover.timer`
polls whichever pipeline is marked "preferred" every 30 seconds, and if it's
remote and its Ollama port isn't actually answering (not just pinging —
ping succeeds on a sleeping Mac; the port doesn't), it pins the satellite to
the local model until the remote one comes back. This is what keeps Harvey
answering fully offline if the bus loses the router or a remote backend goes
to sleep. See `scripts/llm-failover.py`.

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
│   │   ├── harvey_scenes.yaml
│   │   └── harvey_reminders.yaml   ← reminders, timer TTS announce, LLM grounding
│   ├── custom_sentences/en/
│   │   └── harvey_timer_tolerance.yaml  ← STT-misheard timer phrasing
│   ├── openwakeword-models/
│   │   └── hey_harvey.tflite       ← trained custom wake word (optional)
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
│   ├── watchdog.sh         ← Health monitor (incl. stuck-satellite recovery)
│   ├── start-satellite.sh  ← mic/speaker bridge (manual hardware step)
│   ├── satellite-refresh.sh← hourly connection refresh (idle-aware)
│   ├── llm-failover.py     ← auto-switch to local model if remote is down
│   ├── install-wakeword.sh ← watches for + installs a trained wake word
│   ├── oww_onnx_to_tflite.py  ← wake-word ONNX→TFLite converter
│   ├── harvey-warmup.sh    ← preloads the model on boot
│   └── monitor.py          ← live pipeline monitor (desktop shortcut)
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

## Running on Other Machines

**Other Debian/Ubuntu x86_64 boxes:** `install.sh` should work as-is — that's
exactly what it targets (`apt-get`, `systemd`, x86_64 checked at the top).

**Other Linux distros (Fedora, Arch, etc):** the Docker stack itself is
distro-agnostic, but `install.sh` assumes `apt-get` and won't run unmodified.
Not yet adapted — if you need this, the Phase 1/2 package-install lines are
the only truly Debian-specific part; everything past Docker being installed
is distro-neutral.

**macOS — what's realistic today:**
- The "brain" — Home Assistant, Whisper, Piper, OpenWakeWord, Ollama — is
  plain Docker containers and genuinely portable to Docker Desktop for Mac,
  with two changes: drop `network_mode: host` (Docker Desktop for Mac
  doesn't support it the way Linux does) in favor of explicit `ports:`
  mappings, and replace the systemd units with a login item or
  `docker compose up -d` run manually / via a launch agent. Not yet done in
  this repo, but there's no architectural blocker.
- The **physical voice satellite is not portable as-is**: `start-satellite.sh`
  captures/plays audio via raw ALSA commands (`arecord`/`aplay`/`amixer`),
  which are Linux-only — macOS uses CoreAudio instead. Porting the satellite
  itself to a Mac's own mic/speakers would mean a different wyoming-satellite
  audio backend, which hasn't been built here.
- The **proven, already-working pattern** for mixing in a Mac is the one this
  install actually uses: keep voice capture (satellite) and the "brain" on
  the Linux box, and point Ollama at a Mac on the LAN purely as a remote
  inference backend (see *Running the Brain Remotely* above). That's a clean
  network boundary and needs zero porting — it's how the second backend in
  this exact deployment works today.

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
> Note: the Coral is **not** used for wake word or the LLM — openWakeWord's
> models fail to compile for the Edge TPU entirely (confirmed with
> `edgetpu_compiler`: the melspectrogram and hey_jarvis models both fail to
> even load, and the embedding model maps 0 of 64 ops to the TPU since its
> weights are float32, not int8), and an LLM's KV-cache/attention has no
> Edge TPU path in any runtime. Its only real use on this stack is
> accelerating camera object detection (e.g. Frigate) if you add cameras.

**After power outage — checking recovery:**
```bash
systemctl status harvey-stack
docker ps
curl http://localhost:8123/api/  # Should return {"message":"API running."}
```

---

*Harvey Bus Assistant v3 | Venture LLC | MunnymanCommunications*
*Built June 2026*
