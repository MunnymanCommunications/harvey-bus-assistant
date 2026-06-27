# Harvey Bus Assistant — Architecture

## System Overview

Harvey is a fully offline AI smart home assistant running on a Dell x86-64 server with 4GB RAM, optimized for autonomous operation in a mobile environment.

```
VOICE INPUT (Whisper STT)
     ↓
INTENT CLASSIFICATION (Coral TPU)
     ↓
ROUTER (Harvey Router)
     ├→ Simple Command (HA Direct) [<200ms]
     ├→ Complex Query (Qwen2.5-1.5B via Ollama)
     └→ Memory Lookup (SQLite + FTS5)
     ↓
ACTION EXECUTION (Home Assistant)
     ↓
VOICE OUTPUT (Piper TTS)
```

## Hardware Stack

- **CPU:** Dell x86-64 server
- **RAM:** 4GB (configured for 2.85GB typical usage, 4GB swap)
- **GPU:** Google Coral Edge TPU (USB)
- **OS:** Ubuntu (minimal, ~50MB footprint)
- **Storage:** SSD/HDD (at least 10GB free for models)

## Software Stack

### 1. Container Runtime
- **Docker** — orchestrates all services
- **docker-compose** — manages the full stack with automatic restart policies

### 2. Home Automation
- **Home Assistant** — smart home hub
  - Pre-seeded with user account (skip wizard)
  - Pre-configured automations and scenes
  - Runs in Docker, survives reboots
  - Persistent state in `/opt/harvey/ha-config/.storage/`

### 3. Voice Processing (Wyoming Protocol)
- **Whisper STT** (rhasspy/wyoming-whisper)
  - Model: `tiny-int8` (~275MB, ~300MB RAM)
  - Language: English
  - Port: `10300`
  
- **Piper TTS** (rhasspy/wyoming-piper)
  - Voice: `en_US-ryan-medium`
  - Port: `10200`
  - ~150MB RAM
  
- **OpenWakeWord** (rhasspy/wyoming-openwakeword)
  - Wake word: "Hey Jarvis"
  - Coral TPU-accelerated
  - Port: `10400`
  - ~100MB RAM

### 4. Local LLM
- **Ollama** — serves local models
  - Primary: `Qwen2.5-1.5B` (~1.1GB RAM when loaded)
  - Secondary: `nomic-embed-text` (~274MB for embeddings)
  - Runs on CPU (x86-64 optimized)
  - Port: `11434`

### 5. Intent Classification
- **Coral TPU** (optional)
  - Accelerates intent classification
  - Falls back to regex patterns if unavailable
  
- **Harvey Router** (`harvey_router.py`)
  - Routes commands to simple vs. complex handlers
  - Manages HA API calls
  - Caches recent intents for faster response

### 6. Persistent Memory
- **Harvey Memory System** (`harvey_memory.py`)
  - SQLite database at `/opt/harvey/memory/harvey.db`
  - FTS5 full-text search for keyword matching
  - Optional nomic-embed-text for vector similarity
  - Stores:
    - **Semantic facts** (user preferences, explicit statements)
    - **Episode summaries** (auto-compressed conversation history)
    - **Short-term buffer** (last 20 conversation turns)
  - Auto-summarization every 30 turns
  - RAM budget: <50MB idle, <100MB during retrieval

## Systemd Services

All services are defined as systemd units that auto-start and auto-recover:

```
harvey-stack.service
├── Pulls docker-compose.yml
├── Depends on: network-online.target, docker.service
└── Restart: always

ollama.service
├── Runs Ollama LLM server
└── Restart: always

harvey-watchdog.timer
├── Runs watchdog.sh every 2 minutes
├── Checks service health
└── Auto-restarts failed containers
```

## Boot Sequence (Power-Loss Recovery)

1. **Hardware** — BIOS set to "Power On after power loss"
2. **OS** (~10s) — Ubuntu boots with systemd ordering
3. **Docker** (~15s) — docker daemon starts, loads compose file
4. **Ollama** (~20s) — LLM server initializes (doesn't load model yet)
5. **HA Stack** (~60s) — Home Assistant, Wyoming services come online
6. **Ready** (~90s total) — Harvey responsive to voice input

Full recovery time from complete power outage: **~90 seconds**

## RAM Budget (4GB Total)

```
Home Assistant           ~800MB
Whisper (tiny-int8)      ~300MB
Piper TTS                ~150MB
OpenWakeWord             ~100MB
Qwen2.5-1.5B (on query)  ~1.1GB
OS + Docker overhead     ~400MB
─────────────────────────────
Peak usage:              ~2.85GB ✅
Swap buffer:             4GB (rarely used)
```

## Network Architecture

### Offline (Default)
- No external network required
- All services communicate via `localhost`
- Whisper, Piper, OpenWakeWord, Ollama all local

### Hybrid (Optional, with internet)
- Can fall back to cloud APIs (e.g., Gemini) if Ollama slow
- Requires `HA_TOKEN` and optional `GEMINI_KEY`
- Stored in `/opt/harvey/secrets.yaml` (chmod 600)

## Data Persistence

All critical state is stored to survive reboots:

```
/opt/harvey/
├── ha-config/              ← HA config + pre-seeded .storage/
├── memory/harvey.db        ← SQLite persistent memory
├── backups/                ← Auto-backed up DB copies
├── whisper-data/           ← Whisper model cache
├── piper-data/             ← Piper voice models
├── ollama/                 ← Ollama model storage
├── logs/                   ← Service logs
├── ha_token                ← HA long-lived API token (chmod 600)
└── .env                    ← Environment overrides
```

## Security Model

- **Local only** — no cloud AI by default
- **Token-based HA auth** — long-lived token in secure file
- **No passwords in code** — all secrets in `/opt/harvey/secrets.yaml` (chmod 600)
- **USB Coral requires udev** — configured by install script
- **Docker network:** `host` for voice/HA, isolated for other services as needed

## Performance Notes

- **Simple commands** (<200ms) — regex pattern match + HA direct call
- **Complex queries** (~2-5s) — Qwen2.5-1.5B inference on CPU
- **Memory retrieval** (~500ms) — FTS5 keyword search from SQLite
- **Voice latency** (~2s) — Whisper transcription + router + Piper TTS
- **Full round-trip** — user speaks → text → LLM → speech: ~5-8 seconds typical

## Monitoring & Health Checks

1. **systemd** monitors service restarts
2. **Docker healthchecks** on each container (30s interval)
3. **Watchdog timer** (`harvey-watchdog.timer`) runs every 2 minutes
4. **Logs** stored in `/opt/harvey/logs/` for debugging

## Upgrades & Maintenance

- **LLM model swap** — edit `OLLAMA_MODEL` env var, restart
- **Voice model swap** — edit docker-compose.yml `command` fields
- **Memory system** — auto-migrates DB schema, preserves data
- **Config changes** — edit `.yaml` files in `ha-config/`, reload HA via API

See `/docs/memory-system.md` for details on the persistent memory architecture.
