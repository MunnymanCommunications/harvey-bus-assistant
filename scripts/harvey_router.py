#!/usr/bin/env python3
"""
Harvey Intent Router — Coral TPU Edition
Venture LLC | MunnymanCommunications

Routes voice commands:
  - Simple HA commands → Home Assistant directly (no LLM, instant)
  - Complex queries → Qwen2.5-1.5B via Ollama
  - Camera events → Coral TPU object detection

Architecture:
  Whisper STT → This Router → HA or Qwen2.5
                     ↕
                 Coral TPU (intent classification)
"""

import asyncio
import json
import re
import time
import logging
from typing import Optional
import aiohttp

# ── Try Coral TPU runtime ────────────────────────────────────
CORAL_AVAILABLE = False
interpreter = None

try:
    from pycoral.utils.edgetpu import make_interpreter
    from pycoral.adapters import common
    import numpy as np
    CORAL_AVAILABLE = True
    logging.info("✅ Coral Edge TPU available")
except ImportError:
    logging.warning("⚠️  Coral runtime not found — falling back to CPU intent matching")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger("harvey-router")

# ── Configuration ────────────────────────────────────────────
HA_URL = "http://localhost:8123"
HA_TOKEN = "YOUR_HA_LONG_LIVED_TOKEN"  # Set via env var HA_TOKEN
OLLAMA_URL = "http://localhost:11434"
OLLAMA_MODEL = "harvey"  # or "qwen2.5:1.5b"

# ── Simple command patterns (no LLM needed) ──────────────────
# These are handled directly by HA — much faster than LLM
SIMPLE_PATTERNS = [
    # Lights
    (r"\b(turn on|turn off|switch on|switch off|toggle)\b.*(light|lamp|lights)", "light"),
    (r"\b(dim|brighten|set)\b.*(light|lamp)", "light"),
    # Climate
    (r"\b(set|change|adjust)\b.*(temp|temperature|thermostat|heat|cool)", "climate"),
    (r"\b(turn on|turn off)\b.*(heat|ac|fan|air)", "climate"),
    # Locks & security
    (r"\b(lock|unlock)\b.*(door|front|back|bus)", "lock"),
    (r"\b(arm|disarm)\b.*(alarm|security)", "alarm"),
    # Media
    (r"\b(play|pause|stop|skip|next|previous)\b", "media_player"),
    (r"\b(volume up|volume down|mute)\b", "media_player"),
    # Scenes
    (r"\b(movie|sleep|morning|night|away|home)\s+mode\b", "scene"),
    (r"\bgoodnight\b|\bgood night\b", "scene"),
    # Timers
    (r"\b(set|start)\b.*(timer|alarm)\b.*\d+", "timer"),
]

# ── HA service mappings for direct command execution ─────────
HA_SERVICE_MAP = {
    "light_on":    ("light", "turn_on"),
    "light_off":   ("light", "turn_off"),
    "climate_set": ("climate", "set_temperature"),
    "lock":        ("lock", "lock"),
    "unlock":      ("lock", "unlock"),
    "scene":       ("scene", "turn_on"),
    "media_play":  ("media_player", "media_play"),
    "media_pause": ("media_player", "media_pause"),
}


class CoralIntentClassifier:
    """
    Uses Coral TPU to classify intent from voice commands.
    Falls back to regex if Coral not available.
    """

    def __init__(self, model_path: Optional[str] = None):
        self.use_coral = CORAL_AVAILABLE and model_path is not None
        self.interpreter = None

        if self.use_coral:
            try:
                self.interpreter = make_interpreter(model_path)
                self.interpreter.allocate_tensors()
                log.info(f"Coral TPU interpreter loaded: {model_path}")
            except Exception as e:
                log.warning(f"Coral load failed: {e} — using regex fallback")
                self.use_coral = False

    def classify(self, text: str) -> dict:
        """
        Returns:
          {
            "intent": "home_control" | "query" | "timer" | "unknown",
            "confidence": float,
            "backend": "coral" | "regex",
            "entity_type": str or None,
          }
        """
        text_lower = text.lower().strip()

        if self.use_coral:
            return self._classify_coral(text_lower)
        else:
            return self._classify_regex(text_lower)

    def _classify_coral(self, text: str) -> dict:
        """
        Run intent classification on Coral TPU.
        Uses a pre-compiled TFLite intent model.
        """
        try:
            # Tokenize to fixed-length int8 input
            tokens = self._simple_tokenize(text, max_len=64)
            input_data = np.array([tokens], dtype=np.int8)

            common.set_input(self.interpreter, input_data)
            self.interpreter.invoke()
            output = common.output_tensor(self.interpreter, 0)

            # Output: [home_control, query, timer, unknown]
            intents = ["home_control", "query", "timer", "unknown"]
            best_idx = int(np.argmax(output))
            confidence = float(output[best_idx]) / 255.0  # uint8 → 0-1

            return {
                "intent": intents[best_idx],
                "confidence": confidence,
                "backend": "coral",
                "entity_type": None,
            }
        except Exception as e:
            log.warning(f"Coral inference failed: {e}")
            return self._classify_regex(text)

    def _classify_regex(self, text: str) -> dict:
        """Fast regex-based fallback intent classification."""
        for pattern, entity_type in SIMPLE_PATTERNS:
            if re.search(pattern, text, re.IGNORECASE):
                return {
                    "intent": "home_control",
                    "confidence": 0.95,
                    "backend": "regex",
                    "entity_type": entity_type,
                }

        # Check if it's a question / complex query
        query_words = ["what", "how", "when", "where", "why", "who", "tell me",
                       "explain", "weather", "news", "remind", "schedule"]
        if any(text.startswith(w) or f" {w} " in text for w in query_words):
            return {
                "intent": "query",
                "confidence": 0.85,
                "backend": "regex",
                "entity_type": None,
            }

        return {
            "intent": "unknown",
            "confidence": 0.5,
            "backend": "regex",
            "entity_type": None,
        }

    def _simple_tokenize(self, text: str, max_len: int = 64) -> list:
        """Very simple character-level tokenization to int8 for TFLite input."""
        tokens = [min(ord(c), 127) - 64 for c in text[:max_len]]  # ASCII → int8
        return tokens + [0] * (max_len - len(tokens))  # Pad


class HarveyRouter:
    """
    Main router: classifies intent, then routes to HA or Ollama.
    Coral TPU handles classification; CPU handles LLM.
    """

    def __init__(self):
        self.classifier = CoralIntentClassifier(
            # Set this to your compiled intent model path if available:
            model_path=None  # e.g. "/opt/harvey/models/intent_edgetpu.tflite"
        )
        self.ha_session: Optional[aiohttp.ClientSession] = None
        self.ollama_session: Optional[aiohttp.ClientSession] = None

    async def start(self):
        self.ha_session = aiohttp.ClientSession(
            headers={"Authorization": f"Bearer {HA_TOKEN}"}
        )
        self.ollama_session = aiohttp.ClientSession()
        log.info("Harvey Router started")
        log.info(f"  Coral TPU: {'✅ active' if CORAL_AVAILABLE else '⚠️  regex fallback'}")
        log.info(f"  LLM: {OLLAMA_MODEL} via {OLLAMA_URL}")
        log.info(f"  HA: {HA_URL}")

    async def stop(self):
        if self.ha_session:
            await self.ha_session.close()
        if self.ollama_session:
            await self.ollama_session.close()

    async def process(self, text: str) -> str:
        """
        Main entry point. Takes transcribed voice text, returns Harvey's response.
        """
        t0 = time.monotonic()
        log.info(f"Processing: '{text}'")

        # Step 1: Classify intent (Coral TPU or regex)
        result = self.classifier.classify(text)
        log.info(f"Intent: {result['intent']} ({result['backend']}, {result['confidence']:.0%})")

        # Step 2: Route based on intent
        if result["intent"] == "home_control" and result["confidence"] > 0.8:
            # Fast path: send directly to HA, skip LLM entirely
            response = await self._handle_ha_command(text, result)
        else:
            # Complex path: LLM handles it
            response = await self._handle_llm_query(text)

        elapsed = (time.monotonic() - t0) * 1000
        log.info(f"Response in {elapsed:.0f}ms: {response[:80]}...")
        return response

    async def _handle_ha_command(self, text: str, classification: dict) -> str:
        """
        Fast direct path: parse command and call HA service directly.
        No LLM involved — typically <200ms response.
        """
        text_lower = text.lower()

        # Light control
        if "light" in classification.get("entity_type", ""):
            action = "turn_on" if any(w in text_lower for w in
                                      ["on", "turn on", "switch on", "brighten"]) else "turn_off"
            # Call HA
            await self._ha_service_call("light", action, {"entity_id": "light.bus_main"})
            return f"Lights {'on' if action == 'turn_on' else 'off'}."

        # Climate
        if "climate" in classification.get("entity_type", ""):
            # Extract temperature if mentioned
            temp_match = re.search(r"\b(\d{2})\b", text)
            if temp_match:
                temp = int(temp_match.group(1))
                await self._ha_service_call("climate", "set_temperature",
                                            {"entity_id": "climate.bus_thermostat",
                                             "temperature": temp})
                return f"Temperature set to {temp} degrees."
            return "What temperature would you like?"

        # Scene / mode
        if "scene" in classification.get("entity_type", ""):
            if "night" in text_lower or "sleep" in text_lower:
                await self._ha_service_call("scene", "turn_on", {"entity_id": "scene.night_mode"})
                return "Goodnight. Night mode activated."
            elif "morning" in text_lower:
                await self._ha_service_call("scene", "turn_on", {"entity_id": "scene.morning_mode"})
                return "Good morning. Morning mode activated."

        # Fall through to LLM if we couldn't parse
        return await self._handle_llm_query(text)

    async def _handle_llm_query(self, text: str) -> str:
        """
        Complex path: send to Qwen2.5-1.5B via Ollama.
        CPU-bound, ~2-8 seconds on old Dell.
        """
        try:
            payload = {
                "model": OLLAMA_MODEL,
                "prompt": text,
                "stream": False,
                "options": {
                    "temperature": 0.5,
                    "num_predict": 150,  # Keep responses short for voice
                    "num_ctx": 1024,     # Reduced context for RAM savings
                }
            }
            async with self.ollama_session.post(
                f"{OLLAMA_URL}/api/generate",
                json=payload,
                timeout=aiohttp.ClientTimeout(total=30)
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data.get("response", "I couldn't process that request.")
                else:
                    return "I'm having trouble thinking right now. Try again?"
        except asyncio.TimeoutError:
            return "That took too long. Try a simpler question."
        except Exception as e:
            log.error(f"Ollama error: {e}")
            return "Something went wrong with my brain. Try again."

    async def _ha_service_call(self, domain: str, service: str, data: dict):
        """Call a Home Assistant service."""
        try:
            url = f"{HA_URL}/api/services/{domain}/{service}"
            async with self.ha_session.post(url, json=data,
                                            timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status not in (200, 201):
                    log.warning(f"HA service call failed: {resp.status}")
        except Exception as e:
            log.error(f"HA call error: {e}")


# ── Demo / test mode ─────────────────────────────────────────
async def demo():
    """Test the router locally without voice pipeline."""
    import os
    global HA_TOKEN
    HA_TOKEN = os.environ.get("HA_TOKEN", "demo_token")

    router = HarveyRouter()
    await router.start()

    test_commands = [
        "Turn on the lights",
        "Set the temperature to 72 degrees",
        "Goodnight",
        "What's the weather going to be like tomorrow?",
        "How much energy have we used today?",
        "Play some music",
    ]

    print("\n" + "="*60)
    print("HARVEY ROUTER TEST — Coral TPU + Qwen2.5")
    print("="*60 + "\n")

    for cmd in test_commands:
        classification = router.classifier.classify(cmd)
        route = "HA Direct" if classification["intent"] == "home_control" else "Qwen2.5 LLM"
        print(f"  '{cmd}'")
        print(f"  → {route} [{classification['backend']}, {classification['confidence']:.0%}]")
        print()

    await router.stop()


if __name__ == "__main__":
    asyncio.run(demo())
