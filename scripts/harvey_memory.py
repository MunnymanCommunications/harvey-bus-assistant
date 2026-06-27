#!/usr/bin/env python3
"""
Harvey Memory System
Venture LLC | MunnymanCommunications

Persistent memory for Harvey using SQLite + FTS5 + optional vector search.
Runs entirely offline — no cloud, no external APIs.

Memory types:
  1. SHORT-TERM  — rolling conversation buffer (last 20 turns, in-memory)
  2. ENTITY STATE — live HA device states injected before each query
  3. EPISODIC    — past conversations auto-summarized every 30 turns → SQLite
  4. SEMANTIC    — facts extracted from user statements → SQLite + FTS5

Usage:
  memory = HarveyMemory()
  context = await memory.build_context("what temperature does Catalina like?")
  # → injects relevant facts, recent episodes, entity states into prompt
  await memory.save_turn("user", "remember I like it at 70 at night")
  await memory.extract_and_store_fact("user likes bedroom at 70F at night")
"""

import asyncio
import json
import logging
import os
import re
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import aiohttp

log = logging.getLogger("harvey.memory")

# ── Config ────────────────────────────────────────────────────
DB_PATH       = os.environ.get("HARVEY_DB", "/opt/harvey/memory/harvey.db")
BACKUP_DIR    = "/opt/harvey/backups"
OLLAMA_URL    = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL   = "nomic-embed-text"   # pulled via Ollama, ~274MB
SUMMARY_MODEL = os.environ.get("OLLAMA_MODEL", "harvey")
HA_URL        = os.environ.get("HA_URL", "http://localhost:8123")
HA_TOKEN      = os.environ.get("HA_TOKEN", "")

# HA entities to pull as live context (add your real entity IDs here)
WATCHED_ENTITIES = [
    "climate.bus_thermostat",
    "light.bus_main",
    "light.bus_bedroom",
    "lock.bus_door",
    "binary_sensor.bus_motion",
    "sensor.bus_temperature",
    "input_boolean.internet_available",
    "input_select.harvey_ai_mode",
]

MAX_SHORT_TERM   = 20    # turns kept in memory per session
SUMMARIZE_EVERY  = 30    # turns before auto-summarizing
MAX_FACTS_INJECT = 5     # semantic facts injected per query
MAX_EPISODES_INJ = 3     # episode summaries injected per query
MAX_CONTEXT_CHARS= 2000  # total memory context budget (keep LLM context small)


# ─────────────────────────────────────────────────────────────
class HarveyMemory:
    """
    Harvey's persistent memory system.
    Stores facts and episode summaries in SQLite, retrieves by keyword
    relevance (FTS5) with optional vector similarity (nomic-embed-text).
    """

    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        Path(BACKUP_DIR).mkdir(parents=True, exist_ok=True)

        # Short-term memory (in-memory only, reset on restart)
        self._short_term: list[dict] = []
        self._turn_count = 0
        self._session_id = f"session_{int(time.time())}"

        # Embeddings available?
        self._embeddings_ready = False

        self._init_db()
        log.info(f"Harvey Memory initialized at {db_path}")

    def _init_db(self):
        """Create SQLite tables with FTS5 for keyword search."""
        with sqlite3.connect(self.db_path) as conn:
            conn.executescript("""
                -- Semantic facts (things users explicitly tell Harvey)
                CREATE TABLE IF NOT EXISTS facts (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    content     TEXT NOT NULL,
                    category    TEXT DEFAULT 'general',
                    created_at  TEXT NOT NULL,
                    updated_at  TEXT NOT NULL,
                    use_count   INTEGER DEFAULT 0,
                    embedding   BLOB  -- JSON float list, optional
                );

                -- FTS5 index over facts for keyword search
                CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts
                    USING fts5(content, category, content='facts', content_rowid='id');

                -- Episodic memory (summarized past conversations)
                CREATE TABLE IF NOT EXISTS episodes (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id  TEXT NOT NULL,
                    summary     TEXT NOT NULL,
                    turn_range  TEXT,
                    created_at  TEXT NOT NULL,
                    embedding   BLOB
                );

                CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts
                    USING fts5(summary, content='episodes', content_rowid='id');

                -- Raw conversation log (for summarization input)
                CREATE TABLE IF NOT EXISTS turns (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id  TEXT NOT NULL,
                    role        TEXT NOT NULL,
                    content     TEXT NOT NULL,
                    created_at  TEXT NOT NULL,
                    summarized  INTEGER DEFAULT 0
                );

                -- Triggers to keep FTS in sync
                CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
                    INSERT INTO facts_fts(rowid, content, category)
                    VALUES (new.id, new.content, new.category);
                END;

                CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
                    INSERT INTO facts_fts(facts_fts, rowid, content, category)
                    VALUES ('delete', old.id, old.content, old.category);
                END;

                CREATE TRIGGER IF NOT EXISTS episodes_ai AFTER INSERT ON episodes BEGIN
                    INSERT INTO episodes_fts(rowid, summary)
                    VALUES (new.id, new.summary);
                END;
            """)
        log.info("Database tables initialized")

    # ── Short-term (session) memory ───────────────────────────

    def add_turn(self, role: str, content: str):
        """Add a turn to short-term memory and persist to DB."""
        now = datetime.utcnow().isoformat()
        self._short_term.append({"role": role, "content": content, "ts": now})

        # Keep only last MAX_SHORT_TERM turns in memory
        if len(self._short_term) > MAX_SHORT_TERM:
            self._short_term = self._short_term[-MAX_SHORT_TERM:]

        # Persist to DB
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                "INSERT INTO turns (session_id, role, content, created_at) VALUES (?,?,?,?)",
                (self._session_id, role, content, now)
            )

        self._turn_count += 1

        # Auto-summarize every N turns
        if self._turn_count % SUMMARIZE_EVERY == 0:
            asyncio.create_task(self._auto_summarize())

    def get_short_term(self) -> list[dict]:
        """Return recent conversation turns."""
        return self._short_term[-10:]  # last 10 for context

    # ── Semantic facts ─────────────────────────────────────────

    async def store_fact(self, content: str, category: str = "general"):
        """Store a semantic fact (thing user told Harvey)."""
        now = datetime.utcnow().isoformat()
        content = content.strip()
        if not content:
            return

        # Check for duplicate
        with sqlite3.connect(self.db_path) as conn:
            existing = conn.execute(
                "SELECT id FROM facts WHERE content = ?", (content,)
            ).fetchone()
            if existing:
                conn.execute(
                    "UPDATE facts SET updated_at=?, use_count=use_count+1 WHERE id=?",
                    (now, existing[0])
                )
                log.info(f"Updated existing fact: {content[:50]}...")
                return

            # Store new fact
            conn.execute(
                "INSERT INTO facts (content, category, created_at, updated_at) VALUES (?,?,?,?)",
                (content, category, now, now)
            )

        log.info(f"Stored fact [{category}]: {content[:60]}...")

        # Optionally embed (non-blocking)
        asyncio.create_task(self._embed_latest_fact(content))

    async def search_facts(self, query: str, limit: int = MAX_FACTS_INJECT) -> list[str]:
        """Search semantic facts by keyword relevance (FTS5)."""
        with sqlite3.connect(self.db_path) as conn:
            # FTS5 keyword search
            rows = conn.execute(
                """SELECT f.content, f.category
                   FROM facts_fts ft
                   JOIN facts f ON f.id = ft.rowid
                   WHERE facts_fts MATCH ?
                   ORDER BY rank
                   LIMIT ?""",
                (self._fts_query(query), limit)
            ).fetchall()

            if rows:
                results = [f"[{r[1]}] {r[0]}" for r in rows]
                log.debug(f"Facts found: {len(results)}")
                return results

            # Fallback: most recently used facts
            rows = conn.execute(
                "SELECT content, category FROM facts ORDER BY use_count DESC, updated_at DESC LIMIT ?",
                (limit,)
            ).fetchall()
            return [f"[{r[1]}] {r[0]}" for r in rows]

    # ── Episodic memory ────────────────────────────────────────

    async def search_episodes(self, query: str, limit: int = MAX_EPISODES_INJ) -> list[str]:
        """Search episode summaries by keyword relevance."""
        with sqlite3.connect(self.db_path) as conn:
            rows = conn.execute(
                """SELECT e.summary
                   FROM episodes_fts ef
                   JOIN episodes e ON e.id = ef.rowid
                   WHERE episodes_fts MATCH ?
                   ORDER BY rank
                   LIMIT ?""",
                (self._fts_query(query), limit)
            ).fetchall()

            if rows:
                return [r[0] for r in rows]

            # Fallback: most recent episodes
            rows = conn.execute(
                "SELECT summary FROM episodes ORDER BY created_at DESC LIMIT ?",
                (limit,)
            ).fetchall()
            return [r[0] for r in rows]

    async def _auto_summarize(self):
        """Summarize unsummarized turns using Ollama, store as episode."""
        with sqlite3.connect(self.db_path) as conn:
            turns = conn.execute(
                """SELECT role, content FROM turns
                   WHERE session_id=? AND summarized=0
                   ORDER BY created_at""",
                (self._session_id,)
            ).fetchall()

        if len(turns) < 5:
            return

        convo_text = "\n".join(f"{r[0].upper()}: {r[1]}" for r in turns)
        prompt = f"""Summarize this conversation in 2-3 sentences. 
Focus on: what was asked, what actions were taken, any preferences mentioned.
Be specific and concise.

CONVERSATION:
{convo_text}

SUMMARY:"""

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{OLLAMA_URL}/api/generate",
                    json={"model": SUMMARY_MODEL, "prompt": prompt,
                          "stream": False, "options": {"temperature": 0.2, "num_predict": 100}},
                    timeout=aiohttp.ClientTimeout(total=30)
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        summary = data.get("response", "").strip()
                        if summary:
                            now = datetime.utcnow().isoformat()
                            with sqlite3.connect(self.db_path) as conn:
                                conn.execute(
                                    "INSERT INTO episodes (session_id, summary, turn_range, created_at) VALUES (?,?,?,?)",
                                    (self._session_id, summary, f"{len(turns)} turns", now)
                                )
                                conn.execute(
                                    "UPDATE turns SET summarized=1 WHERE session_id=? AND summarized=0",
                                    (self._session_id,)
                                )
                            log.info(f"Auto-summarized {len(turns)} turns")
        except Exception as e:
            log.warning(f"Auto-summarize failed: {e}")

    # ── Entity state from Home Assistant ──────────────────────

    async def get_entity_states(self) -> str:
        """Fetch current HA entity states for context injection."""
        if not HA_TOKEN:
            return ""

        states = []
        try:
            async with aiohttp.ClientSession(
                headers={"Authorization": f"Bearer {HA_TOKEN}"}
            ) as session:
                for entity_id in WATCHED_ENTITIES:
                    try:
                        async with session.get(
                            f"{HA_URL}/api/states/{entity_id}",
                            timeout=aiohttp.ClientTimeout(total=3)
                        ) as resp:
                            if resp.status == 200:
                                data = await resp.json()
                                state = data.get("state", "unknown")
                                attrs = data.get("attributes", {})
                                name = attrs.get("friendly_name", entity_id)
                                # Include temp if climate
                                extra = ""
                                if "temperature" in attrs:
                                    extra = f" ({attrs['temperature']}°F)"
                                states.append(f"{name}: {state}{extra}")
                    except Exception:
                        pass
        except Exception as e:
            log.debug(f"HA state fetch error: {e}")

        return "\n".join(states) if states else ""

    # ── Fact extraction ────────────────────────────────────────

    async def maybe_extract_fact(self, text: str) -> Optional[str]:
        """
        If the user's message contains a preference or memory request,
        extract and store it. Returns the extracted fact or None.
        """
        text_lower = text.lower()

        # Explicit memory triggers
        triggers = [
            "remember that", "remember,", "don't forget",
            "i prefer", "i like", "i want", "i always",
            "catalina likes", "catalina prefers", "nic likes", "nic prefers",
            "we usually", "we always", "set it to always",
            "my favorite", "our favorite",
        ]

        if not any(t in text_lower for t in triggers):
            return None

        # Determine category
        category = "general"
        if any(w in text_lower for w in ["temp", "heat", "cool", "thermostat", "degree"]):
            category = "climate"
        elif any(w in text_lower for w in ["light", "bright", "dim", "dark"]):
            category = "lighting"
        elif any(w in text_lower for w in ["sleep", "wake", "morning", "night", "bed"]):
            category = "schedule"
        elif any(w in text_lower for w in ["catalina", "nic", "we", "our"]):
            category = "person"

        # Clean up the fact text
        fact = text.strip()
        # Remove command prefixes
        for prefix in ["remember that ", "remember, ", "don't forget that "]:
            if fact.lower().startswith(prefix):
                fact = fact[len(prefix):]
                break

        await self.store_fact(fact, category)
        return fact

    # ── Context builder (the main output) ─────────────────────

    async def build_context(self, query: str) -> str:
        """
        Build the memory context block to inject into Harvey's system prompt.
        Retrieves relevant facts, recent episodes, and live HA entity states.
        Stays under MAX_CONTEXT_CHARS to protect RAM.
        """
        sections = []
        char_budget = MAX_CONTEXT_CHARS

        # 1. Live entity states (always include, most relevant)
        entity_states = await self.get_entity_states()
        if entity_states:
            block = f"CURRENT HOME STATUS:\n{entity_states}"
            sections.append(block)
            char_budget -= len(block)

        # 2. Relevant semantic facts
        if char_budget > 200:
            facts = await self.search_facts(query)
            if facts:
                block = "KNOWN PREFERENCES & FACTS:\n" + "\n".join(f"• {f}" for f in facts)
                if len(block) <= char_budget:
                    sections.append(block)
                    char_budget -= len(block)

        # 3. Relevant episode summaries
        if char_budget > 200:
            episodes = await self.search_episodes(query)
            if episodes:
                block = "PAST CONTEXT:\n" + "\n".join(f"• {e}" for e in episodes)
                if len(block) <= char_budget:
                    sections.append(block)
                    char_budget -= len(block)

        # 4. Recent short-term turns
        if char_budget > 100:
            recent = self.get_short_term()
            if recent:
                lines = [f"{t['role'].upper()}: {t['content']}" for t in recent[-5:]]
                block = "RECENT CONVERSATION:\n" + "\n".join(lines)
                if len(block) <= char_budget:
                    sections.append(block)

        return "\n\n".join(sections)

    # ── Helpers ────────────────────────────────────────────────

    def _fts_query(self, text: str) -> str:
        """Convert free text to FTS5 query (AND of significant words)."""
        stop_words = {"the", "a", "an", "is", "are", "was", "what", "how",
                      "can", "you", "i", "it", "to", "and", "or", "of", "do"}
        words = re.findall(r'\b\w{3,}\b', text.lower())
        keywords = [w for w in words if w not in stop_words]
        if not keywords:
            return text
        return " OR ".join(keywords[:5])  # FTS5 OR query

    async def _embed_latest_fact(self, content: str):
        """Optionally embed a fact using nomic-embed-text (non-blocking)."""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{OLLAMA_URL}/api/embeddings",
                    json={"model": EMBED_MODEL, "prompt": content},
                    timeout=aiohttp.ClientTimeout(total=15)
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        embedding = data.get("embedding", [])
                        if embedding:
                            blob = json.dumps(embedding).encode()
                            with sqlite3.connect(self.db_path) as conn:
                                conn.execute(
                                    "UPDATE facts SET embedding=? WHERE content=?",
                                    (blob, content)
                                )
                            self._embeddings_ready = True
                            log.debug(f"Embedded fact: {content[:40]}...")
        except Exception:
            pass  # Embeddings are optional — FTS5 fallback always works

    def backup(self):
        """Copy DB to backup directory (called by watchdog)."""
        import shutil
        ts = datetime.now().strftime("%Y%m%d_%H%M")
        dst = f"{BACKUP_DIR}/harvey_{ts}.db"
        shutil.copy2(self.db_path, dst)
        # Keep only last 7 backups
        backups = sorted(Path(BACKUP_DIR).glob("harvey_*.db"))
        for old in backups[:-7]:
            old.unlink()
        log.info(f"Memory backed up to {dst}")

    def stats(self) -> dict:
        """Return memory statistics."""
        with sqlite3.connect(self.db_path) as conn:
            facts_count = conn.execute("SELECT COUNT(*) FROM facts").fetchone()[0]
            episodes_count = conn.execute("SELECT COUNT(*) FROM episodes").fetchone()[0]
            turns_count = conn.execute("SELECT COUNT(*) FROM turns").fetchone()[0]
        return {
            "facts": facts_count,
            "episodes": episodes_count,
            "turns_total": turns_count,
            "turns_session": self._turn_count,
            "short_term_size": len(self._short_term),
            "embeddings_enabled": self._embeddings_ready,
            "db_size_kb": round(Path(self.db_path).stat().st_size / 1024, 1)
                          if Path(self.db_path).exists() else 0,
        }


# ── CLI test ───────────────────────────────────────────────────
async def demo():
    """Quick smoke test of the memory system."""
    logging.basicConfig(level=logging.INFO)
    mem = HarveyMemory("/tmp/harvey_test.db")

    print("\n=== Harvey Memory Demo ===\n")

    # Store some facts
    await mem.store_fact("Catalina prefers the bedroom at 70°F at night", "climate")
    await mem.store_fact("Nic likes the main lights at 40% in the evening", "lighting")
    await mem.store_fact("The bus solar panels charge best when parked south-facing", "general")
    await mem.store_fact("We usually leave the bus around 9am on travel days", "schedule")

    # Simulate a conversation
    mem.add_turn("user", "What temperature should the bedroom be tonight?")
    mem.add_turn("assistant", "I've set the bedroom to 70°F as Catalina prefers.")
    mem.add_turn("user", "Remember that Nic gets cold below 68")
    await mem.maybe_extract_fact("Remember that Nic gets cold below 68")

    # Build context for a query
    print("Building context for: 'what should the temperature be?'")
    context = await mem.build_context("what should the temperature be?")
    print("\n--- Context Block ---")
    print(context or "(no context — HA not running in demo)")
    print("--- End Context ---\n")

    print("Memory Stats:", json.dumps(mem.stats(), indent=2))


if __name__ == "__main__":
    asyncio.run(demo())
