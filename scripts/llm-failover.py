#!/usr/bin/python3
"""
Harvey LLM failover — keeps the voice satellite pointed at a reachable
conversation agent.

The satellite is normally left on "preferred" so that whatever is picked in
Settings -> Voice assistants drives both voice and text. The catch is that a
preferred pipeline backed by a remote Ollama (the Mac) goes silent the moment
that machine sleeps or the WiFi drops: Home Assistant puts no timeout on the
call, so the satellite wedges in 'processing' until the watchdog restarts it
and no reply is ever spoken.

So probe the preferred backend, and when it is remote and unreachable, pin the
satellite to a local pipeline instead so Harvey keeps answering fully offline.
Restore it to "preferred" as soon as the remote comes back.
"""
import json
import socket
import sys
import urllib.error
import urllib.request
from datetime import datetime
from urllib.parse import urlparse

HA = "http://localhost:8123"
STORAGE = "/opt/harvey/ha-config/.storage"
TOKEN_FILE = "/opt/harvey/ha_token"
SELECT_ENTITY = "select.harvey_satellite_assistant"
LOG = "/opt/harvey/logs/failover.log"
STATE_FILE = "/opt/harvey/logs/llm-backend.state"

PROBE_TIMEOUT = 4
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]"}


def log(msg):
    line = "[%s] %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line)


def load(name):
    with open("%s/%s" % (STORAGE, name)) as f:
        return json.load(f)


def ha_request(path, method="GET", payload=None):
    with open(TOKEN_FILE) as f:
        token = f.read().strip()
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(HA + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read()
    return json.loads(body) if body else None


def agent_urls():
    """Map each conversation entity to the Ollama URL backing it."""
    entities = load("core.entity_registry")["data"]["entities"]
    entries = {e["entry_id"]: e for e in load("core.config_entries")["data"]["entries"]}
    out = {}
    for ent in entities:
        eid = ent.get("entity_id", "")
        if not eid.startswith("conversation."):
            continue
        entry = entries.get(ent.get("config_entry_id"))
        if entry and entry.get("domain") == "ollama":
            out[eid] = entry.get("data", {}).get("url")
    return out


def is_local(url):
    if not url:
        return False
    host = urlparse(url).hostname
    return host in LOCAL_HOSTS


def reachable(url):
    """A backend counts as up only if Ollama actually answers, not just if the
    host pings — a sleeping Mac still replies to ICMP while port 11434 is dead."""
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/api/tags", timeout=PROBE_TIMEOUT):
            return True
    except (urllib.error.URLError, socket.timeout, OSError):
        return False


def main():
    pipelines = load("assist_pipeline.pipelines")["data"]
    items = pipelines["items"]
    preferred_id = pipelines.get("preferred_item")
    urls = agent_urls()

    preferred = next((p for p in items if p["id"] == preferred_id), None)
    if preferred is None:
        log("no preferred pipeline set — leaving satellite alone")
        return 0

    pref_url = urls.get(preferred["conversation_engine"])

    # A local fallback needs to be a full voice pipeline (STT + TTS), otherwise
    # failing over to it would trade a silent assistant for a deaf one.
    fallback = next(
        (
            p
            for p in items
            if p["id"] != preferred_id
            and is_local(urls.get(p["conversation_engine"]))
            and p.get("stt_engine")
            and p.get("tts_engine")
        ),
        None,
    )

    if pref_url is None or is_local(pref_url):
        # Preferred is local (or not an Ollama agent at all) — nothing to fail
        # over to or from; just follow it.
        target, why = "preferred", "preferred pipeline %r is local" % preferred["name"]
    elif reachable(pref_url):
        target, why = "preferred", "%s reachable at %s" % (preferred["name"], pref_url)
    elif fallback is None:
        log("%s unreachable at %s but no local pipeline to fall back to" % (preferred["name"], pref_url))
        return 0
    else:
        target = fallback["name"]
        why = "%s UNREACHABLE at %s — falling back to %s" % (
            preferred["name"],
            pref_url,
            fallback["name"],
        )

    try:
        current = ha_request("/api/states/" + SELECT_ENTITY)["state"]
    except Exception as err:
        log("could not read %s (%s) — skipping" % (SELECT_ENTITY, err))
        return 0

    # Record what is actually serving right now so the live monitor can show it.
    serving = preferred if target == "preferred" else fallback
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(
                {
                    "pipeline": serving["name"],
                    "agent": serving["conversation_engine"],
                    "url": urls.get(serving["conversation_engine"]),
                    "failed_over": target != "preferred",
                    "updated": datetime.now().isoformat(timespec="seconds"),
                },
                f,
            )
    except OSError:
        pass

    if current == target:
        return 0

    try:
        ha_request(
            "/api/services/select/select_option",
            method="POST",
            payload={"entity_id": SELECT_ENTITY, "option": target},
        )
    except Exception as err:
        log("failed to set %s to %r: %s" % (SELECT_ENTITY, target, err))
        return 1

    log("satellite %r -> %r (%s)" % (current, target, why))
    return 0


if __name__ == "__main__":
    sys.exit(main())
