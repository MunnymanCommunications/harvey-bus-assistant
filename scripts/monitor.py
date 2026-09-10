#!/usr/bin/env python3
"""
Harvey live pipeline monitor — run this in its own terminal to watch
the full voice pipeline in real time: satellite state changes, what
Whisper transcribed, what Harvey is saying back, and which machine
(Dell or Mac) actually produced the answer.
"""
import asyncio
import json
import re
import subprocess
import sys
import time
from datetime import datetime

STORAGE = "/opt/harvey/ha-config/.storage"
STATE_FILE = "/opt/harvey/logs/llm-backend.state"
FAILOVER_LOG = "/opt/harvey/logs/failover.log"

HA_TOKEN = subprocess.run(
    ["sudo", "cat", "/opt/harvey/ha_token"], capture_output=True, text=True
).stdout.strip()
HA_WS_URL = "ws://localhost:8123/api/websocket"
SATELLITE_LOG = "/opt/harvey/logs/satellite.log"

RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
MAGENTA = "\033[95m"
CYAN = "\033[96m"
GREY = "\033[90m"
BOLD = "\033[1m"
RESET = "\033[0m"

# Which backend answered the current turn. Set from the Home Assistant log as
# each reply comes in, then used to tag the spoken line.
current_backend = "?"

# Last reply printed, so the same text is not shown twice if a synthesize
# event does arrive alongside the streamed one.
last_reply = ""

# Last thing YOU SAID (from the satellite log), so the "Processing in
# en:" line -- which fires for the same voice turn AND for typed HA-app
# queries -- only prints when it is not just repeating that line.
last_transcript = ""


def ts():
    return datetime.now().strftime("%H:%M:%S")


def _sudo_json(path):
    out = subprocess.run(["sudo", "cat", path], capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None


def build_labels():
    """Map conversation agents and model tags to a human label, so a reply can
    be attributed to the Dell or the Mac. Labels come from the pipeline names
    set in Home Assistant, so renaming a pipeline there renames it here too."""
    agents, models = {}, {}
    try:
        reg = _sudo_json(STORAGE + "/core.entity_registry")
        cfg = _sudo_json(STORAGE + "/core.config_entries")
        pipes = _sudo_json(STORAGE + "/assist_pipeline.pipelines")
        entries = {e["entry_id"]: e for e in cfg["data"]["entries"]}
        pipeline_name = {
            p["conversation_engine"]: p["name"] for p in pipes["data"]["items"]
        }
        for ent in reg["data"]["entities"]:
            eid = ent.get("entity_id", "")
            if not eid.startswith("conversation."):
                continue
            entry = entries.get(ent.get("config_entry_id"))
            if not entry or entry.get("domain") != "ollama":
                continue
            model = next(
                (s["data"].get("model") for s in entry.get("subentries", [])), None
            )
            name = pipeline_name.get(eid) or entry.get("data", {}).get("url", eid)
            name = name.replace("Harvey ", "").strip("() ")
            agents[eid] = name
            if model:
                models[model] = name
    except Exception:
        pass
    return agents, models


AGENT_LABELS, MODEL_LABELS = build_labels()


def active_wake_word():
    """Read the wake word the satellite is actually configured with, rather than
    assuming — it changes whenever a custom model is installed."""
    try:
        out = subprocess.run(["sudo", "cat", "/opt/harvey/scripts/start-satellite.sh"],
                             capture_output=True, text=True).stdout
        m = re.search(r'--wake-word-name "([^"]+)"', out)
        if m:
            return m.group(1).replace("_", " ").title()
    except Exception:
        pass
    return "the wake word"


def active_backend():
    """What the failover service says is serving right now."""
    try:
        st = _sudo_json(STATE_FILE)
        if not st:
            return None
        tag = st["pipeline"]
        if st.get("failed_over"):
            tag += " (failed over — preferred host unreachable)"
        return tag
    except Exception:
        return None


def tail_satellite_log():
    """Follow the satellite log and print transcript/synthesize/error/wake events."""
    proc = subprocess.Popen(
        ["sudo", "tail", "-F", "-n", "0", SATELLITE_LOG],
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    transcript_re = re.compile(r"Event\(type='transcript', data=\{'text': \"(.*?)\"\}")
    transcript_re2 = re.compile(r"Event\(type='transcript', data=\{'text': '(.*?)'\}")
    synthesize_re = re.compile(r"Event\(type='synthesize', data=\{'text': '(.*?)'")
    error_re = re.compile(r"Event\(type='error', data=\{'code': '(.*?)', 'message': '(.*?)'\}")
    error_re2 = re.compile(r"Event\(type='error', data=\{'text': '(.*?)', 'code': '(.*?)'\}")

    for line in proc.stdout:
        line = line.rstrip()
        m = transcript_re.search(line) or transcript_re2.search(line)
        if m:
            global last_transcript
            last_transcript = m.group(1).strip()
            print(f"{CYAN}[{ts()}] {BOLD}YOU SAID:{RESET}{CYAN} \"{last_transcript}\"{RESET}")
            continue
        m = synthesize_re.search(line)
        if m:
            if m.group(1).strip() == last_reply:
                continue
            print(
                f"{GREEN}[{ts()}] {BOLD}HARVEY SAYS{RESET}{GREEN} "
                f"{BOLD}[{current_backend}]{RESET}{GREEN}: \"{m.group(1).strip()}\"{RESET}"
            )
            continue
        m = error_re.search(line)
        if m:
            print(f"{RED}[{ts()}] {BOLD}ERROR:{RESET}{RED} {m.group(2)} (code: {m.group(1)}){RESET}")
            continue
        m = error_re2.search(line)
        if m:
            print(f"{RED}[{ts()}] {BOLD}ERROR:{RESET}{RED} {m.group(1)} (code: {m.group(2)}){RESET}")
            continue
        if "Streaming audio" in line:
            print(f"{MAGENTA}[{ts()}] wake word detected — streaming audio to Whisper...{RESET}")


def tail_ha_ai_log():
    """Follow HA's own container log for AI activity — the authoritative source
    for which backend was called and how long it took. The per-token streaming
    deltas are skipped; only the routing, timing and errors are printed."""
    global current_backend
    proc = subprocess.Popen(
        ["docker", "logs", "-f", "-n", "0", "homeassistant"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    # Piper/Whisper live under the wyoming and tts components, so leaving them
    # out here hides a dead synthesizer: the pipeline just stops after the
    # conversation result with nothing printed at all.
    keywords = ("ollama", "conversation", "assist_pipeline", "wyoming", "tts", "piper")
    # Bookkeeping chatter that either repeats what the satellite already showed
    # or dumps the whole system prompt on every turn.
    noise = (
        "speech-to-text result",  # duplicates YOU SAID
        "Adding user content",
        "Prompt: [SystemContent",
        "Tools: None",
        "Initialized microVAD",
        "conversation result ConversationResult",
    )
    ansi_re = re.compile(r"\033\[[0-9;]*m")
    asked_re = re.compile(r"Processing in \w+:\s*(.*)")
    agent_re = re.compile(r"agent_id='([\w.]+)'")
    model_re = re.compile(r"model='([^']+)'")
    reply_re = re.compile(r'content=(["\'])(.*?)\1, thinking_content=')
    done_re = re.compile(
        r"done=True.*?total_duration=(\d+).*?prompt_eval_count=(\d+).*?eval_count=(\d+)"
    )
    # Mirrors assist_pipeline's own STREAM_RESPONSE_CHARS=60 threshold: once
    # this many characters have streamed in, HA fires the real "start
    # speaking now" trigger -- well before the full reply is generated.
    # HARVEY SAYS (below) only fires once generation is fully done, so on its
    # own it understates how early Harvey should actually start talking.
    delta_content_re = re.compile(r"'content': (['\"])((?:(?!\1).)*)\1")
    stream_chars = 0
    stream_marked = False
    gen_start = None

    for line in proc.stdout:
        line = ansi_re.sub("", line.rstrip())
        lower = line.lower()
        problem = " error " in lower or " warning " in lower
        if not problem and not any(k in lower for k in keywords):
            continue
        if "Adding user content" in line:
            stream_chars = 0
            stream_marked = False
            gen_start = time.monotonic()
            continue
        if any(n in line for n in noise):
            continue
        if problem:
            print(f"{RED}[{ts()}] {BOLD}HA:{RESET}{RED} {line}{RESET}")
            continue

        # Streaming deltas: one line per token. Only the final one is useful,
        # except we also tally characters as they arrive to catch the exact
        # moment HA's real 60-char streaming trigger should fire.
        if "Received response:" in line or "Received delta" in line:
            if not stream_marked:
                cm = delta_content_re.search(line)
                if cm:
                    stream_chars += len(cm.group(2))
                    if stream_chars > 60:
                        stream_marked = True
                        el = time.monotonic() - gen_start if gen_start else 0
                        print(
                            f"{MAGENTA}[{ts()}] {BOLD}TTS should start now{RESET}"
                            f"{MAGENTA} — ~60 chars generated ({el:.1f}s into "
                            f"this reply){RESET}"
                        )
            m = done_re.search(line)
            if m:
                model = model_re.search(line)
                if model and model.group(1) in MODEL_LABELS:
                    current_backend = MODEL_LABELS[model.group(1)]
                print(
                    f"{GREY}[{ts()}] llm done — {int(m.group(1))/1e9:.1f}s, "
                    f"{m.group(2)} prompt + {m.group(3)} reply tokens "
                    f"({model.group(1) if model else '?'}){RESET}"
                )
            continue

        # Catches questions typed into Home Assistant, which never reach the
        # satellite and so have no "YOU SAID" line of their own.
        m = asked_re.search(line)
        if m:
            if m.group(1).strip() != last_transcript:
                print(f"{CYAN}[{ts()}] {BOLD}ASKED:{RESET}{CYAN} \"{m.group(1).strip()}\"{RESET}")
            continue

        if "Adding assistant content" in line:
            m = agent_re.search(line)
            if m:
                current_backend = AGENT_LABELS.get(m.group(1), m.group(1))
            # With streaming TTS the satellite never receives a single
            # 'synthesize' event, so the spoken text is only visible here.
            t = reply_re.search(line)
            if t:
                global last_reply
                last_reply = t.group(2).strip()
                print(
                    f"{GREEN}[{ts()}] {BOLD}HARVEY SAYS{RESET}{GREEN} "
                    f"{BOLD}[{current_backend}]{RESET}{GREEN}: \"{last_reply}\"{RESET}"
                )
            else:
                print(f"{YELLOW}[{ts()}] answered by {BOLD}{current_backend}{RESET}")
            continue

        print(f"{YELLOW}[{ts()}] AI LOG:{RESET}{YELLOW} {line}{RESET}")


def tail_failover_log():
    """Announce automatic Dell/Mac switchovers as they happen."""
    proc = subprocess.Popen(
        ["sudo", "tail", "-F", "-n", "0", FAILOVER_LOG],
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    for line in proc.stdout:
        line = line.rstrip()
        if line:
            print(f"{MAGENTA}{BOLD}[{ts()}] BACKEND SWITCH:{RESET}{MAGENTA} {line}{RESET}")


async def watch_satellite_state():
    """Subscribe to HA state_changed events for the satellite entity."""
    import websockets

    async with websockets.connect(HA_WS_URL, open_timeout=10) as ws:
        await ws.recv()
        await ws.send(json.dumps({"type": "auth", "access_token": HA_TOKEN}))
        auth = json.loads(await ws.recv())
        if auth.get("type") != "auth_ok":
            print(f"{RED}HA auth failed{RESET}")
            return
        await ws.send(json.dumps({"id": 1, "type": "subscribe_events", "event_type": "state_changed"}))
        await ws.recv()
        print(f"{BLUE}{BOLD}=== Harvey Live Pipeline Monitor ==={RESET}")
        print(f"{BLUE}Connected to Home Assistant. Say \"{active_wake_word()}\" to test.{RESET}")
        backend = active_backend()
        if backend:
            print(f"{BLUE}Answering right now: {BOLD}{backend}{RESET}\n")
        else:
            print()
        async for message in ws:
            data = json.loads(message)
            if data.get("type") != "event":
                continue
            event_data = data.get("event", {}).get("data", {})
            entity = event_data.get("entity_id")
            new_state = event_data.get("new_state", {}) or {}
            if entity == "assist_satellite.harvey_satellite":
                print(f"{BLUE}[{ts()}] satellite state -> {BOLD}{new_state.get('state')}{RESET}")
            elif entity == "select.harvey_satellite_assistant":
                print(
                    f"{MAGENTA}{BOLD}[{ts()}] satellite now using:{RESET}"
                    f"{MAGENTA} {new_state.get('state')}{RESET}"
                )


async def heartbeat():
    """Print a quiet pulse periodically so it's obvious the monitor is alive
    and connected even when nothing has happened for a while."""
    while True:
        await asyncio.sleep(30)
        backend = active_backend() or "unknown"
        print(f"{GREY}[{ts()}] (still connected — {backend} — waiting for \"{active_wake_word()}\"...){RESET}")


async def main():
    loop = asyncio.get_event_loop()
    loop.run_in_executor(None, tail_satellite_log)
    loop.run_in_executor(None, tail_ha_ai_log)
    loop.run_in_executor(None, tail_failover_log)
    asyncio.create_task(heartbeat())
    await watch_satellite_state()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
