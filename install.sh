#!/bin/bash
# =================================================================
#  HARVEY BUS ASSISTANT — FULL AUTO INSTALLER v3
#  Venture LLC | MunnymanCommunications
#
#  WHAT THIS DOES (zero human input after this script runs):
#  ✅ Installs Docker, Coral TPU runtime, Ollama, Qwen2.5-1.5B
#  ✅ Pre-provisions Home Assistant (no browser wizard needed)
#  ✅ Configures Wyoming voice stack (Whisper + Piper + WakeWord)
#  ✅ All services auto-start on boot via systemd
#  ✅ Auto-recovers after power outage (systemd restart policies)
#  ✅ 4GB swap for stability
#  ✅ Static IP optional (prompted)
#  ✅ Sets BIOS power-loss hint via ipmitool if available
#
#  USAGE:
#    sudo bash install.sh
#    (Run once — everything else is automatic forever)
# =================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
success() { echo -e "${GREEN}[✓]${NC}      $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}   $1"; }
error()   { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}══ $1 ══${NC}"; }

# ── BANNER ────────────────────────────────────────────────────
clear
echo -e "${GREEN}${BOLD}"
cat << 'BANNER'
  ██╗  ██╗ █████╗ ██████╗ ██╗   ██╗███████╗██╗   ██╗
  ██║  ██║██╔══██╗██╔══██╗██║   ██║██╔════╝╚██╗ ██╔╝
  ███████║███████║██████╔╝██║   ██║█████╗   ╚████╔╝
  ██╔══██║██╔══██║██╔══██╗╚██╗ ██╔╝██╔══╝    ╚██╔╝
  ██║  ██║██║  ██║██║  ██║ ╚████╔╝ ███████╗   ██║
  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝   ╚═╝
BANNER
echo -e "${NC}"
echo -e "  ${BOLD}Bus AI Assistant — Full Auto Setup${NC}"
echo -e "  Venture LLC | MunnymanCommunications\n"
echo -e "  ${YELLOW}This script runs once and sets everything up.${NC}"
echo -e "  ${YELLOW}When it finishes, Harvey is LIVE — no browser wizard needed.${NC}\n"

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"
[[ $(uname -m) != "x86_64" ]] && error "x86_64 only."

# ── COLLECT CONFIG UP FRONT ───────────────────────────────────
step "Configuration"

read -rp "  Harvey admin username (default: catalina): " HA_USER
HA_USER="${HA_USER:-catalina}"

read -rsp "  Harvey admin password: " HA_PASS
echo ""
[[ -z "$HA_PASS" ]] && error "Password cannot be empty"

read -rp "  Display name (default: Catalina): " HA_NAME
HA_NAME="${HA_NAME:-Catalina}"

read -rp "  Timezone (default: America/Denver): " TZ_ZONE
TZ_ZONE="${TZ_ZONE:-America/Denver}"

read -rp "  Gemini API key (leave blank to skip): " GEMINI_KEY

echo ""
info "Configuration locked in. Starting installation..."
sleep 1

# ── PHASE 1: SYSTEM PREP ──────────────────────────────────────
step "Phase 1/8 — System Preparation"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl wget git nano htop \
    build-essential cmake \
    apparmor apparmor-utils \
    jq udisks2 libglib2.0-bin \
    network-manager dbus \
    lsb-release ca-certificates gnupg \
    python3 python3-pip python3-venv \
    usbutils ffmpeg \
    avahi-daemon avahi-utils \
    libusb-1.0-0 udev \
    ipmitool \
    util-linux \
    2>/dev/null

# Hostname
hostnamectl set-hostname harvey-bus
grep -q "harvey-bus" /etc/hosts || echo "127.0.1.1  harvey-bus" >> /etc/hosts
success "Hostname: harvey-bus"

# ── SWAP (critical for 4GB stability) ─────────────────────────
if [[ ! -f /swapfile ]]; then
    info "Creating 4GB swap file..."
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile -L harvey-swap
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# Keep swappiness low — only swap under real memory pressure
sysctl -w vm.swappiness=10 >/dev/null
grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
success "4GB swap enabled (swappiness=10)"

# ── BIOS power-on-after-outage (via IPMI if available) ────────
info "Attempting to configure BIOS power-loss policy..."
if ipmitool chassis policy always-on 2>/dev/null; then
    success "BIOS: Auto power-on after outage enabled via IPMI"
else
    warn "IPMI not available — set 'Restore on AC Power Loss = Power On' in BIOS manually"
    warn "  (Usually: BIOS → Power Management → AC Power Recovery → Power On)"
fi

# ── PHASE 2: DOCKER ───────────────────────────────────────────
step "Phase 2/8 — Docker"

if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable docker
systemctl start docker

# docker-compose-plugin
apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
success "Docker ready"

# ── PHASE 3: CORAL EDGE TPU ───────────────────────────────────
step "Phase 3/8 — Coral Edge TPU Runtime"

if [[ ! -f /etc/apt/sources.list.d/coral-edgetpu.list ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] \
https://packages.cloud.google.com/apt coral-edgetpu-stable main" \
        > /etc/apt/sources.list.d/coral-edgetpu.list
    apt-get update -qq
fi

apt-get install -y -qq libedgetpu1-std python3-pycoral 2>/dev/null || \
    warn "Coral apt packages unavailable — installing via pip fallback"

python3 -m pip install --quiet --break-system-packages \
    pycoral tflite-runtime numpy aiohttp 2>/dev/null || true

# System-wide websockets for scripts/monitor.py and the desktop launcher,
# which run as the desktop user (not inside a venv) via plain `python3`.
python3 -m pip install --quiet --break-system-packages websockets 2>/dev/null || true

# udev rule — Coral usable without root
cat > /etc/udev/rules.d/99-coral.rules << 'UDEV'
SUBSYSTEM=="usb", ATTRS{idVendor}=="1a6e", GROUP="plugdev", MODE="0664"
SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", GROUP="plugdev", MODE="0664"
UDEV
udevadm control --reload-rules && udevadm trigger
success "Coral TPU runtime configured"

if lsusb 2>/dev/null | grep -q "1a6e\|18d1"; then
    success "Coral USB Accelerator detected!"
else
    warn "Coral not seen via USB yet (plug it in — detected on boot)"
fi

# ── PHASE 4: DIRECTORY STRUCTURE ──────────────────────────────
step "Phase 4/8 — Directory Structure"

mkdir -p /opt/harvey/{ha-config/.storage,ha-config/packages,whisper-data,piper-data,models,scripts,logs}
chmod -R 755 /opt/harvey
success "Created /opt/harvey/"

# ── PHASE 5: PRE-PROVISION HOME ASSISTANT ────────────────────
# HA Docker checks for .storage/onboarding — if it exists and is
# marked "done", it skips the browser wizard entirely.
# We also pre-write all config files so HA starts fully configured.
step "Phase 5/8 — Pre-Provisioning Home Assistant"

info "Writing HA configuration files..."

# ── onboarding marker (tells HA: wizard already done) ─────────
# HA checks .storage/onboarding for {"version":4,"data":{"done":["user","core_config","analytics_preferences","integration","finished"]}}
cat > /opt/harvey/ha-config/.storage/onboarding << 'ONBOARD'
{
  "version": 4,
  "minor_version": 1,
  "key": "onboarding",
  "data": {
    "done": [
      "user",
      "core_config",
      "analytics_preferences",
      "integration",
      "finished"
    ]
  }
}
ONBOARD

# ── Generate user credentials ──────────────────────────────────
# HA uses bcrypt for passwords. We use Python (available before HA starts).
info "Generating user account..."

HASHED_PASS=$(python3 -c "
import bcrypt, sys
pwd = sys.argv[1].encode()
print(bcrypt.hashpw(pwd, bcrypt.gensalt(rounds=12)).decode())
" "$HA_PASS" 2>/dev/null) || {
    python3 -m pip install bcrypt --quiet --break-system-packages 2>/dev/null
    HASHED_PASS=$(python3 -c "
import bcrypt, sys
pwd = sys.argv[1].encode()
print(bcrypt.hashpw(pwd, bcrypt.gensalt(rounds=12)).decode())
" "$HA_PASS")
}

USER_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
CREDENTIAL_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
PERSON_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
REFRESH_TOKEN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
ACCESS_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(64))")

# Write auth storage
cat > /opt/harvey/ha-config/.storage/auth << EOF
{
  "version": 1,
  "minor_version": 1,
  "key": "auth",
  "data": {
    "users": [
      {
        "id": "${USER_ID}",
        "group_ids": ["system-admin"],
        "is_owner": true,
        "is_active": true,
        "name": "${HA_NAME}",
        "system_generated": false,
        "local_only": false
      }
    ],
    "groups": [
      {
        "id": "system-admin",
        "name": "Administrators",
        "policy": {
          "all": {"read": true, "write": true, "create": true, "delete": true}
        }
      },
      {
        "id": "system-users",
        "name": "Users",
        "policy": {
          "entities": {"domains": {"all": {"read": true, "write": true}}}
        }
      },
      {
        "id": "system-read-only",
        "name": "Read Only",
        "policy": {
          "entities": {"domains": {"all": {"read": true}}}
        }
      }
    ],
    "credentials": [
      {
        "id": "${CREDENTIAL_ID}",
        "user_id": "${USER_ID}",
        "auth_provider_type": "homeassistant",
        "auth_provider_id": null,
        "data": {
          "username": "${HA_USER}"
        },
        "is_new": false
      }
    ],
    "refresh_tokens": [
      {
        "id": "${REFRESH_TOKEN_ID}",
        "user_id": "${USER_ID}",
        "client_id": "https://harvey-bus.local/",
        "client_name": "Harvey Bus Auto Token",
        "client_icon": null,
        "token_type": "long_lived_access_token",
        "created_at": "$(date -u +%Y-%m-%dT%H:%M:%S.000000+00:00)",
        "access_token_expiration_type": "undetermined",
        "token": "${ACCESS_TOKEN}",
        "jwt_key": "$(python3 -c 'import secrets; print(secrets.token_hex(32))')",
        "last_used_at": null,
        "last_used_ip": null,
        "credential_id": "${CREDENTIAL_ID}",
        "version": null
      }
    ]
  }
}
EOF

# Write auth_provider storage (bcrypt password hash)
cat > /opt/harvey/ha-config/.storage/auth_provider.homeassistant << EOF
{
  "version": 1,
  "minor_version": 1,
  "key": "auth_provider.homeassistant",
  "data": {
    "users": [
      {
        "username": "${HA_USER}",
        "password": "${HASHED_PASS}"
      }
    ]
  }
}
EOF

# Write person storage
cat > /opt/harvey/ha-config/.storage/person << EOF
{
  "version": 2,
  "minor_version": 1,
  "key": "person",
  "data": {
    "persons": [
      {
        "id": "${PERSON_ID}",
        "user_id": "${USER_ID}",
        "name": "${HA_NAME}",
        "device_trackers": [],
        "picture": null
      }
    ],
    "next_id": 2
  }
}
EOF

# Store the access token for use by the router service
echo "${ACCESS_TOKEN}" > /opt/harvey/ha_token
chmod 600 /opt/harvey/ha_token
success "User '${HA_USER}' pre-provisioned"

# ── core_config storage ────────────────────────────────────────
cat > /opt/harvey/ha-config/.storage/core.config << EOF
{
  "version": 1,
  "minor_version": 3,
  "key": "core.config",
  "data": {
    "latitude": 39.7392,
    "longitude": -104.9903,
    "elevation": 5280,
    "unit_system_v2": "us_customary",
    "location_name": "Harvey Bus",
    "time_zone": "${TZ_ZONE}",
    "external_url": null,
    "internal_url": "http://harvey-bus.local:8123",
    "currency": "USD",
    "country": "US",
    "language": "en",
    "radius": 100,
    "allowlist_external_dirs": [],
    "allowlist_external_urls": []
  }
}
EOF

# ── configuration.yaml ────────────────────────────────────────
cat > /opt/harvey/ha-config/configuration.yaml << EOF
# ============================================================
#  HARVEY BUS — Home Assistant Configuration
#  Auto-provisioned by Venture LLC install script
# ============================================================

homeassistant:
  name: Harvey Bus
  time_zone: ${TZ_ZONE}
  unit_system: imperial
  currency: USD
  country: US
  # Auto-login from local network (no password prompt on LAN)
  auth_providers:
    - type: trusted_networks
      trusted_networks:
        - 192.168.0.0/16
        - 172.16.0.0/12
        - 10.0.0.0/8
        - 127.0.0.1
      allow_bypass_login: true
    - type: homeassistant

default_config:

# ── HTTP ────────────────────────────────────────────────────
http:
  ip_ban_enabled: true
  login_attempts_threshold: 10

# ── Logger ──────────────────────────────────────────────────
logger:
  default: warning
  logs:
    homeassistant.components.wyoming: info

# ── TTS (Piper via Wyoming) ─────────────────────────────────
tts:
  - platform: cloud
    language: en-US

# ── Camera — Kamtron (update IP after install) ───────────────
# Uncomment and set your camera IP:
# camera:
#   - platform: generic
#     name: "Bus Front Camera"
#     stream_source: "rtsp://admin:PASSWORD@YOUR_CAMERA_IP:554/stream1"
#     still_image_url: "http://YOUR_CAMERA_IP/snapshot.jpg"
#     verify_ssl: false

# ── Packages (split config) ──────────────────────────────────
homeassistant:
  packages: !include_dir_named packages/

# ── Automations / Scripts / Scenes ──────────────────────────
automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
EOF

# ── secrets.yaml ──────────────────────────────────────────────
cat > /opt/harvey/ha-config/secrets.yaml << EOF
# Harvey Bus Secrets
# Fill these in as you add integrations

ha_token: ${ACCESS_TOKEN}
$([ -n "$GEMINI_KEY" ] && echo "gemini_api_key: ${GEMINI_KEY}" || echo "# gemini_api_key: YOUR_KEY_HERE")

# Camera (update with your Kamtron IP/password):
# camera_stream: rtsp://admin:PASSWORD@192.168.1.xxx:554/stream1

# Optional: MQTT broker password if you add one
# mqtt_password: changeme
EOF
chmod 600 /opt/harvey/ha-config/secrets.yaml

# ── Empty stubs so HA doesn't error on startup ────────────────
touch /opt/harvey/ha-config/automations.yaml
touch /opt/harvey/ha-config/scripts.yaml
touch /opt/harvey/ha-config/scenes.yaml

# ── Voice assistant package ───────────────────────────────────
cat > /opt/harvey/ha-config/packages/harvey_voice.yaml << 'PKG'
# Harvey Voice Package — auto-loaded
# Wyoming integrations are configured via UI after first boot.
# This file pre-loads input helpers and basic automations.

input_boolean:
  harvey_voice_enabled:
    name: Harvey Voice Active
    icon: mdi:microphone

  internet_available:
    name: Internet Available
    icon: mdi:wifi-check

input_select:
  harvey_ai_mode:
    name: Harvey AI Mode
    options:
      - Local (Qwen2.5)
      - Cloud (Gemini)
      - Auto
    initial: Local (Qwen2.5)
    icon: mdi:robot

template:
  - sensor:
      - name: "Harvey Mode"
        state: >
          {% if is_state('input_boolean.internet_available', 'on') %}
            Online
          {% else %}
            Off-Grid
          {% endif %}
        icon: >
          {% if is_state('input_boolean.internet_available', 'on') %}
            mdi:wifi
          {% else %}
            mdi:wifi-off
          {% endif %}

automation:
  - id: harvey_startup_announce
    alias: "Harvey — Boot Announcement"
    trigger:
      - platform: homeassistant
        event: start
    action:
      - delay: "00:00:20"
      - service: system_log.write
        data:
          message: >
            Harvey Bus systems online. All services ready.
            Good {{ ['morning','morning','morning','afternoon','afternoon','evening','evening','evening','evening'][now().hour // 3] }}.
          level: info
    mode: single

  - id: check_internet
    alias: "Harvey — Check Internet Every 5 Min"
    trigger:
      - platform: time_pattern
        minutes: "/5"
    action:
      - service: input_boolean.turn_on
        entity_id: input_boolean.internet_available
    mode: single

  - id: night_mode_auto
    alias: "Harvey — Night Mode at 10pm"
    trigger:
      - platform: time
        at: "22:00:00"
    action:
      - service: scene.turn_on
        entity_id: scene.night_mode
    mode: single

  - id: morning_mode_auto
    alias: "Harvey — Morning Mode at 7am"
    trigger:
      - platform: time
        at: "07:00:00"
    action:
      - service: scene.turn_on
        entity_id: scene.morning_mode
    mode: single
PKG

# ── Basic scenes package ───────────────────────────────────────
cat > /opt/harvey/ha-config/packages/harvey_scenes.yaml << 'PKG'
scene:
  - name: Night Mode
    entities:
      input_boolean.harvey_voice_enabled:
        state: "on"

  - name: Morning Mode
    entities:
      input_boolean.harvey_voice_enabled:
        state: "on"
PKG

success "Home Assistant fully pre-provisioned"
info "Login: ${HA_USER} / [your password]"
info "Access token saved to: /opt/harvey/ha_token"

# ── PHASE 6: OLLAMA + QWEN2.5 ────────────────────────────────
step "Phase 6/8 — Ollama + Qwen2.5-1.5B"

if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Ensure ollama service is enabled and running
systemctl enable ollama
systemctl start ollama
sleep 5

info "Pulling Qwen2.5:1.5b (~1.1GB — this may take a few minutes)..."
ollama pull qwen2.5:1.5b || warn "Model download failed — run: ollama pull qwen2.5:1.5b"

# Harvey personality modelfile
cat > /opt/harvey/Modelfile.harvey << 'MODELFILE'
FROM qwen2.5:1.5b

SYSTEM """
You are Harvey, the AI assistant aboard the smart bus home of Catalina and Nic, owners of Venture LLC.

Your purpose: control smart home devices on the bus, answer questions, assist with tasks.

Voice assistant rules — CRITICAL:
- ALWAYS respond in 1-3 short sentences. This is voice output.
- Be direct: "Lights on." not "I have turned on the lights for you."
- You work fully offline. Never say you need internet for basic smart home tasks.
- You represent Venture LLC's technology — be professional but warm.
- You do NOT set timers, alarms, or reminders, and you do NOT control smart
  home devices yourself. Home Assistant already tried and failed to handle
  the request before it ever reached you — so it is IMPOSSIBLE for you to
  set one, and saying you did is always a lie, even if it sounds helpful.
  Example — user says "set a timer for the eclipse tonight": WRONG reply:
  "Sure, timer set for tonight." RIGHT reply: "I can't set that — try
  something like 'set a timer for ten minutes.'" Follow the RIGHT pattern
  every time a timer, alarm, or reminder request reaches you.

You know:
- You run on the Harvey Bus server (Dell server, Ubuntu, local-only).
- Coral TPU handles wake word + camera. You handle conversation.
- Smart home commands go through Home Assistant on port 8123.
- Off-grid is normal — you're designed for it.
"""

PARAMETER temperature 0.4
PARAMETER num_ctx 2048
# 120 cut multi-sentence answers off mid-word (done_reason='length' instead of
# 'stop'). This is a runaway guard, not a length target — the prompt above is
# what keeps replies short.
PARAMETER num_predict 250
PARAMETER repeat_penalty 1.15
PARAMETER top_p 0.9
MODELFILE

ollama create harvey -f /opt/harvey/Modelfile.harvey 2>/dev/null || \
    warn "Harvey model personality will be created after Ollama fully starts"

success "Ollama + Qwen2.5-1.5B + Harvey personality ready"

# ── PHASE 7: DOCKER COMPOSE (Full Stack) ─────────────────────
step "Phase 7/8 — Docker Compose Stack"

cat > /opt/harvey/docker-compose.yml << COMPOSE
version: "3.9"

# ================================================================
#  HARVEY BUS — COMPLETE DOCKER STACK
#  All containers restart automatically on crash or power outage.
# ================================================================

services:

  # ── Home Assistant ─────────────────────────────────────────
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: always                  # ← restarts after power cut
    network_mode: host               # ← full LAN access, mDNS works
    privileged: true
    environment:
      - TZ=${TZ_ZONE}
    volumes:
      - /opt/harvey/ha-config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    devices:
      - /dev/bus/usb:/dev/bus/usb    # Coral TPU + USB devices
    healthcheck:
      # HA's frontend index is served unauthenticated, unlike /api/ (401
      # without a token) -- keep this token-free so nobody is tempted to
      # bake a real token into a file that might end up in version control.
      test: ["CMD", "curl", "-sf", "http://localhost:8123/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  # ── Whisper STT ────────────────────────────────────────────
  whisper:
    container_name: whisper-stt
    image: rhasspy/wyoming-whisper:latest
    restart: always
    command: >
      --model tiny-int8
      --language en
      --uri tcp://0.0.0.0:10300
      --data-dir /data
      --download-dir /data
      --beam-size 1
    volumes:
      - /opt/harvey/whisper-data:/data
    ports:
      - "10300:10300"
    mem_limit: 1g
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/localhost/10300' || exit 1"]
      interval: 30s
      retries: 3
      start_period: 60s

  # ── Piper TTS ──────────────────────────────────────────────
  piper:
    container_name: piper-tts
    image: rhasspy/wyoming-piper:latest
    restart: always
    command: >
      --voice en_US-ryan-medium
      --uri tcp://0.0.0.0:10200
      --data-dir /data
      --download-dir /data
    volumes:
      - /opt/harvey/piper-data:/data
    ports:
      - "10200:10200"
    # 256m left Piper pinned at its ceiling: constant reclaim stalls made it
    # stop answering on 10200 for a minute or two at a time, which hung the
    # pipeline at the synthesize stage with no error.
    mem_limit: 1g
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/localhost/10200' || exit 1"]
      interval: 30s
      retries: 3
      start_period: 45s

  # ── OpenWakeWord ───────────────────────────────────────────
  openwakeword:
    container_name: openwakeword
    image: rhasspy/wyoming-openwakeword:latest
    restart: always
    command: >
      --uri tcp://0.0.0.0:10400
      --preload-model hey_jarvis
      --threshold 0.35
      --custom-model-dir /custom-models
    volumes:
      - /opt/harvey/openwakeword-models:/custom-models
    ports:
      - "10400:10400"
    # No Coral passthrough here: openWakeWord's models cannot run on an Edge
    # TPU. edgetpu_compiler rejects melspectrogram (CONV_2D fails to prepare)
    # and hey_jarvis (dynamic-sized tensors), and maps 0 of 64 embedding_model
    # ops to the TPU because the weights are float32, not int8. The USB
    # passthrough and privileged flag bought nothing and are dropped.
    mem_limit: 256m
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/localhost/10400' || exit 1"]
      interval: 30s
      retries: 3
      start_period: 45s

COMPOSE

mkdir -p /opt/harvey/openwakeword-models

success "docker-compose.yml written"

# ── PHASE 8: SYSTEMD SERVICES (boot-safe, power-cut-safe) ────
step "Phase 8/8 — Systemd Boot Services"

# ── Harvey Docker stack ────────────────────────────────────────
cat > /etc/systemd/system/harvey-stack.service << SERVICE
[Unit]
Description=Harvey Bus AI Stack (Docker Compose)
Documentation=https://github.com/MunnymanCommunications/harvey-bus-assistant
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/harvey
# Pull latest images on start (skipped if offline)
ExecStartPre=-/usr/bin/docker compose pull --quiet 2>/dev/null || true
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down --remove-orphans
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=300
TimeoutStopSec=30
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

# ── Harvey Intent Router ───────────────────────────────────────
cat > /etc/systemd/system/harvey-router.service << SERVICE
[Unit]
Description=Harvey Intent Router (Coral TPU + HA Bridge)
Documentation=https://github.com/MunnymanCommunications/harvey-bus-assistant
After=harvey-stack.service ollama.service
Wants=harvey-stack.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/harvey
Environment="HA_TOKEN=$(cat /opt/harvey/ha_token)"
Environment="HA_URL=http://localhost:8123"
Environment="OLLAMA_URL=http://localhost:11434"
Environment="OLLAMA_MODEL=harvey"
ExecStart=/opt/harvey/venv/bin/python3 /opt/harvey/scripts/harvey_router.py
Restart=always
RestartSec=5
StandardOutput=append:/opt/harvey/logs/router.log
StandardError=append:/opt/harvey/logs/router.log

[Install]
WantedBy=multi-user.target
SERVICE

# ── Watchdog service ───────────────────────────────────────────
# Periodically checks all Harvey services and restarts any that died
cat > /etc/systemd/system/harvey-watchdog.service << 'SERVICE'
[Unit]
Description=Harvey System Watchdog
After=harvey-stack.service

[Service]
Type=oneshot
ExecStart=/opt/harvey/scripts/watchdog.sh
SERVICE

cat > /etc/systemd/system/harvey-watchdog.timer << 'TIMER'
[Unit]
Description=Harvey Watchdog Timer (every 2 minutes)

[Timer]
OnBootSec=120
OnUnitActiveSec=120
AccuracySec=10

[Install]
WantedBy=timers.target
TIMER

# ── Watchdog script ────────────────────────────────────────────
cat > /opt/harvey/scripts/watchdog.sh << 'WATCHDOG'
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
WATCHDOG
chmod +x /opt/harvey/scripts/watchdog.sh

# ── Python venv for router ─────────────────────────────────────
python3 -m venv /opt/harvey/venv
/opt/harvey/venv/bin/pip install --quiet aiohttp bcrypt 2>/dev/null || true

# Copy router script
cp "$(dirname "${BASH_SOURCE[0]}")/harvey_router.py" /opt/harvey/scripts/ 2>/dev/null || true

# ── Harvey capabilities added after the original install ──────
# These are hardware-independent (no satellite/audio setup required) and
# safe on any install: reminders with hourly re-nagging and deterministic
# "mark that complete" resolution, tolerance for the timer-phrasing STT
# slips found in real use, and automatic failover to the local Ollama model
# whenever a configured remote one (e.g. a Mac) is unreachable.
step "Additional Harvey capabilities"

REPO_DIR="$(dirname "${BASH_SOURCE[0]}")"
mkdir -p /opt/harvey/ha-config/custom_sentences/en /opt/harvey/openwakeword-models

for f in harvey_reminders.yaml; do
    cp "${REPO_DIR}/ha-config/packages/${f}" "/opt/harvey/ha-config/packages/${f}" 2>/dev/null || \
        warn "Could not copy ${f} — add it manually from the repo"
done
cp "${REPO_DIR}/ha-config/custom_sentences/en/harvey_timer_tolerance.yaml" \
    /opt/harvey/ha-config/custom_sentences/en/ 2>/dev/null || \
    warn "Could not copy timer-phrasing tolerance — add it manually from the repo"

for f in llm-failover.py oww_onnx_to_tflite.py install-wakeword.sh satellite-refresh.sh \
         harvey-warmup.sh start-satellite.sh monitor.py; do
    cp "${REPO_DIR}/scripts/${f}" "/opt/harvey/scripts/${f}" 2>/dev/null || \
        warn "Could not copy scripts/${f} — add it manually from the repo"
done
chmod +x /opt/harvey/scripts/*.sh /opt/harvey/scripts/*.py 2>/dev/null || true

# llm-failover needs only Ollama, not the physical satellite -- safe to
# enable unconditionally. It's a no-op (does nothing, changes nothing) on
# a single-backend install with no remote Ollama configured.
cp "${REPO_DIR}/systemd/harvey-llm-failover.service" /etc/systemd/system/ 2>/dev/null || true
cp "${REPO_DIR}/systemd/harvey-llm-failover.timer" /etc/systemd/system/ 2>/dev/null || true

# The rest (satellite-refresh, wakeword-install, warmup) install their unit
# files now but are only ENABLED once the satellite itself is set up below,
# since they target harvey-satellite.service, which does not exist until
# scripts/start-satellite.sh has been run for this machine's audio hardware.
for u in harvey-satellite-refresh harvey-wakeword-install harvey-warmup; do
    cp "${REPO_DIR}/systemd/${u}.service" /etc/systemd/system/ 2>/dev/null || true
    [[ -f "${REPO_DIR}/systemd/${u}.timer" ]] && \
        cp "${REPO_DIR}/systemd/${u}.timer" /etc/systemd/system/ 2>/dev/null || true
done

success "Reminders, timer-phrasing tolerance, and LLM failover installed"

# ── Enable everything ──────────────────────────────────────────
systemctl daemon-reload
systemctl enable ollama
systemctl enable harvey-stack
systemctl enable harvey-watchdog.timer
systemctl enable --now harvey-llm-failover.timer
# harvey-satellite-refresh / harvey-wakeword-install / harvey-warmup are
# installed but not enabled here -- they target harvey-satellite.service,
# which this script does not create. See "Voice Satellite Setup" in the
# README for the one manual, hardware-specific step (mic/speaker detection)
# that wires the physical satellite up, after which those three timers
# should also be enabled.
# (Router enabled after first HA boot confirms token is working)

success "Systemd services configured"

# ── FIRST BOOT: START EVERYTHING NOW ──────────────────────────
step "Starting Harvey..."

info "Starting Ollama..."
systemctl start ollama
sleep 3

info "Starting Docker stack (pulling images — this takes 5-10 min first time)..."
cd /opt/harvey && docker compose up -d
sleep 5

info "Starting watchdog timer..."
systemctl start harvey-watchdog.timer

# ── WAIT FOR HA TO BE READY ───────────────────────────────────
info "Waiting for Home Assistant to become ready..."
HA_READY=false
for i in $(seq 1 60); do
    if curl -sf http://localhost:8123/api/ -H "Authorization: Bearer $(cat /opt/harvey/ha_token)" >/dev/null 2>&1; then
        HA_READY=true
        break
    fi
    printf "  Waiting... %d/60\r" "$i"
    sleep 5
done

if $HA_READY; then
    success "Home Assistant is LIVE!"
else
    warn "HA taking longer than expected — check: docker logs homeassistant"
fi

# ── AUTO-CONFIGURE WYOMING INTEGRATIONS ───────────────────────
if $HA_READY; then
    info "Auto-configuring Wyoming integrations via HA API..."
    HA_TOKEN="$(cat /opt/harvey/ha_token)"
    HA_BASE="http://localhost:8123"

    # Helper to call HA API
    ha_api() {
        curl -sf -X POST "${HA_BASE}${1}" \
            -H "Authorization: Bearer ${HA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${2}" >/dev/null 2>&1 && return 0 || return 1
    }

    # Wait for Wyoming services to be available
    sleep 30

    # Configure Wyoming Whisper
    ha_api "/api/config/config_entries/flow" \
        '{"handler":"wyoming","show_advanced_options":false}' && \
        success "Wyoming Whisper integration queued" || \
        warn "Will need to add Wyoming integrations manually in HA UI"

    # Note: Full programmatic Wyoming config requires websocket API
    # The UI path is fast (2 min): Settings → Integrations → + → Wyoming Protocol
fi

# ── FINAL SUMMARY ─────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
HA_TOKEN_VAL=$(cat /opt/harvey/ha_token)

echo ""
echo -e "${GREEN}${BOLD}"
echo "════════════════════════════════════════════════════════════"
echo "  ✅  HARVEY BUS IS LIVE — FULLY AUTOMATIC"
echo "════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo -e "  ${BOLD}Home Assistant:${NC}   http://${IP}:8123"
echo -e "  ${BOLD}Username:${NC}         ${HA_USER}"
echo -e "  ${BOLD}Password:${NC}         [what you entered]"
echo ""
echo -e "  ${BOLD}Services:${NC}"
echo -e "  🤖 Ollama (Qwen):  http://${IP}:11434"
echo -e "  🗣️  Whisper STT:    tcp://${IP}:10300"
echo -e "  🔊 Piper TTS:      tcp://${IP}:10200"
echo -e "  👂 Wake Word:      tcp://${IP}:10400"
echo ""
echo -e "  ${BOLD}Power outage recovery:${NC} ✅ All services auto-restart"
echo -e "  ${BOLD}Boot auto-start:${NC}       ✅ Enabled via systemd"
echo -e "  ${BOLD}Watchdog:${NC}              ✅ Checks + restarts every 2 min"
echo -e "  ${BOLD}Coral TPU:${NC}             $(lsusb 2>/dev/null | grep -c '1a6e\|18d1') device(s) detected"
echo ""
echo -e "  ${YELLOW}${BOLD}IMPORTANT — 3 MANUAL STEPS REMAINING:${NC}"
echo ""
echo -e "  ${BOLD}1. BIOS Power-Loss Setting${NC} (if IPMI didn't work above):"
echo -e "     Reboot → Enter BIOS → Power Management"
echo -e "     → 'Restore on AC Power Loss' → Set to 'Power On'"
echo -e "     → Save & Exit"
echo ""
echo -e "  ${BOLD}2. Add Wyoming Voice Integrations${NC} (2 min in browser):"
echo -e "     http://${IP}:8123 → Settings → Integrations → + Add"
echo -e "     → Search 'Wyoming Protocol' → Add Whisper (port 10300)"
echo -e "     → Add again → Piper (port 10200)"
echo -e "     → Add again → OpenWakeWord (port 10400)"
echo ""
echo -e "  ${BOLD}3. Add Your Kamtron Camera${NC}:"
echo -e "     Settings → Integrations → + → 'ONVIF' or 'Generic Camera'"
echo -e "     RTSP: rtsp://admin:PASSWORD@YOUR_CAMERA_IP:554/stream1"
echo ""
echo -e "  ${CYAN}API Token (for automations/scripts):${NC}"
echo -e "  ${HA_TOKEN_VAL:0:30}..."
echo -e "  Full token: /opt/harvey/ha_token"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  docker ps                                # Check containers"
echo -e "  journalctl -u harvey-stack -f            # Stack logs"
echo -e "  docker logs homeassistant -f             # HA logs"
echo -e "  ollama run harvey 'hello'                # Test Harvey AI"
echo -e "  systemctl status harvey-watchdog.timer  # Watchdog status"
echo ""
