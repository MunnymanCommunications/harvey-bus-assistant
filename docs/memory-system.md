# Harvey Memory System — Complete Guide

## Overview

Harvey's memory system provides persistent, context-aware responses by storing and retrieving:
1. **User preferences** (semantic facts)
2. **Conversation history** (episodic summaries)
3. **Device state** (live HA entities)
4. **Short-term context** (last 20 conversation turns)

All offline. No cloud. Survives reboots.

## Architecture

```
Harvey Memory System
├── SHORT-TERM (in-memory)
│   └── Last 20 conversation turns (reset on restart)
│
├── ENTITY STATE (live)
│   └── Climate, lights, locks, sensors pulled from HA each query
│
├── EPISODIC (SQLite + FTS5)
│   └── Auto-summarized past conversations (30-turn windows)
│
└── SEMANTIC (SQLite + FTS5/vectors)
    └── Explicit facts ("I like 70F", "Catalina prefers quiet", etc.)
```

## Database Schema

SQLite database at `/opt/harvey/memory/harvey.db`

### facts table
```sql
CREATE TABLE facts (
    id          INTEGER PRIMARY KEY,
    content     TEXT NOT NULL,        -- "Catalina prefers temp 70F at night"
    category    TEXT DEFAULT 'general',
    created_at  TEXT NOT NULL,        -- ISO timestamp
    updated_at  TEXT NOT NULL,
    use_count   INTEGER DEFAULT 0,    -- retrieval frequency
    embedding   BLOB                  -- JSON float array (optional)
);
```

### episodes table
```sql
CREATE TABLE episodes (
    id          INTEGER PRIMARY KEY,
    session_id  TEXT NOT NULL,        -- "session_1719532800"
    summary     TEXT NOT NULL,        -- "Discussed temperature settings..."
    turn_range  TEXT,                 -- "turns 1-30"
    created_at  TEXT NOT NULL,
    embedding   BLOB                  -- JSON float array (optional)
);
```

### turns table (raw conversation log)
```sql
CREATE TABLE turns (
    id          INTEGER PRIMARY KEY,
    session_id  TEXT NOT NULL,
    role        TEXT NOT NULL,        -- "user" or "assistant"
    content     TEXT NOT NULL,        -- full message text
    created_at  TEXT NOT NULL,
    summarized  INTEGER DEFAULT 0     -- marked after episode creation
);
```

### FTS5 Virtual Tables
- `facts_fts` — keyword search over facts
- `episodes_fts` — keyword search over summaries

## Memory Types Explained

### 1. SHORT-TERM Memory (Session Buffer)

**What:** Last 20 conversation turns kept in-memory  
**When reset:** On Harvey restart  
**Use case:** Recent context within same conversation  
**RAM cost:** ~50KB per 20 turns (text-only)

Example: User asks "what did I say about the lights?" → checked in short-term first

### 2. ENTITY STATE (Live Device Context)

**What:** Current state of watched HA entities  
**Pulled:** Before every query  
**Entities:** Thermostat, lights, locks, sensors, climate  

Example: `climate.bus_thermostat` → "currently 72F, target 70F, heating" → injected in prompt

```python
WATCHED_ENTITIES = [
    "climate.bus_thermostat",
    "light.bus_main",
    "lock.bus_door",
    "sensor.bus_temperature",
    # ... add your entities here
]
```

### 3. EPISODIC Memory (Conversation Summaries)

**What:** Compressed summaries of past conversations  
**Trigger:** Automatically every 30 turns  
**Compression:** Qwen2.5-1.5B summarizes 30-turn chunks  
**Storage:** SQLite + FTS5

Example:
```
Turn 1-30 summary:
"User discussed heating preferences. Likes 70F at night, 
 72F during day. Concerned about bathroom ventilation. 
 Prefers gradual temperature changes."
 
Stored as one episode row, marked ready for FTS5 search.
```

**Retention:** Indefinite (survives reboots)  
**Retrieval:** Top 3 most relevant episodes injected per query  
**RAM cost:** Zero (all on disk)

### 4. SEMANTIC Memory (Explicit Facts)

**What:** Extracted user preferences & facts  
**Created:** When Harvey recognizes "remember...", "I prefer...", "Catalina likes..." patterns  
**Extraction:** Ollama NLU → structured fact → stored

Example facts:
```
"Catalina prefers the bedroom at 70F at night"
"Bathroom fan should run for 10 minutes after shower"
"Don't play music between 10pm-8am"
```

**Storage:** SQLite facts table + FTS5 index  
**Retrieval:** Top 5 facts by keyword relevance injected per query  
**Embeddings:** Optional vector similarity via nomic-embed-text (if available)

## Dynamic Prompt Construction

Each query gets a fresh system prompt built from:

```python
context = """
BASE_PERSONALITY:
You are Harvey, a smart home assistant...

RELEVANT SEMANTIC FACTS:
- Catalina prefers temp 70F at night
- User dislikes noisy fans
- [top 5 facts by similarity to query]

RECENT EPISODES:
Yesterday we discussed: [3-turn summary]

CURRENT DEVICE STATE:
Thermostat: 72F (heating to 70F)
Main light: off
Bedroom light: on (brightness 80%)
Front door: locked
[all WATCHED_ENTITIES states]

CONVERSATION HISTORY:
Human: [last turn]
Assistant: [last response]
Human: [this turn]
"""
```

**Total context budget:** 2000 characters max (keeps LLM token usage low for 4GB RAM)

## Auto-Summarization

Every 30 conversation turns:

1. Extract all unsummarized turns from SQLite
2. Prompt Qwen2.5-1.5B: "Summarize this conversation in 1-2 sentences, focusing on preferences and decisions"
3. Store episode summary + turn range
4. Mark original turns as `summarized=1`
5. Short-term buffer resets

**RAM savings:** 30 turns of text (potentially 5KB) → 1 episode summary (200 chars) = 25x compression

## Fact Extraction

When Harvey hears patterns like:
- "Remember that..."
- "I prefer..."
- "Catalina likes..."
- "Don't..."
- "Always..."

Example:
```
User: "Remember that I like it at 70F at night"
↓
Harvey extracts fact: "User prefers 70F at night"
↓
Stores in SQLite facts table with:
  - content: "User prefers 70F at night"
  - category: "preferences"
  - created_at: [timestamp]
  - use_count: 0 (incremented each retrieval)
```

## Retrieval Strategy (Hybrid)

When building prompt context:

1. **Short-term first:** Check last 20 turns in-memory
2. **Keyword search (FTS5):** "temperature" → match fact with "temp", "heating", "thermostat"
3. **Vector search (optional):** Use nomic-embed-text to find semantic similarities
4. **Entity state:** Query HA API for live device states
5. **Combine & rank:** Merge results by relevance, take top N

```python
# Pseudocode
facts = db.search_facts(query_text)  # FTS5
episodes = db.search_episodes(query_text)  # FTS5
entity_state = ha_api.fetch_entities()
context = build_prompt(facts, episodes, entity_state)
```

## Configuration

In `harvey_memory.py`:

```python
MAX_SHORT_TERM   = 20      # turns in memory
SUMMARIZE_EVERY  = 30      # turns before auto-summarize
MAX_FACTS_INJECT = 5       # facts to inject per query
MAX_EPISODES_INJ = 3       # episodes to inject per query
MAX_CONTEXT_CHARS= 2000    # total memory context budget
```

## Files & Locations

```
/opt/harvey/
├── memory/
│   └── harvey.db              ← SQLite database (all memory)
├── backups/
│   └── harvey.db.YYYYMMDD     ← Daily backups (auto)
├── scripts/
│   └── harvey_memory.py       ← Memory system (runs in router)
└── logs/
    └── memory.log             ← Memory debug logs
```

**Database size:** Typically 1-10MB after months of use (facts + episodes + FTS index)

## Backup & Recovery

- **Auto-backup:** Database copied to `/opt/harvey/backups/` daily
- **Corruption recovery:** If DB corrupted, copy from backups/ back to memory/
- **Full reset:** Delete `harvey.db` to start fresh (short-term buffer resets anyway)

## Embeddings (Optional)

If you want semantic vector search instead of keyword-only:

```python
# Install
pip install sqlite-vec

# In memory system: pull nomic-embed-text model
ollama pull nomic-embed-text

# Then extract & store vectors for facts:
embedding = await ollama_embed(fact_content)
db.store_embedding(fact_id, embedding)

# Retrieval: vector similarity + FTS5 hybrid search
```

**Fallback:** If embeddings unavailable, system still works with FTS5 keyword search.

## Performance Notes

- **Memory lookup:** <500ms (SQLite FTS5 very fast)
- **Summarization:** ~3s (Qwen2.5-1.5B inference)
- **Fact extraction:** ~1s (pattern matching + LLM validation)
- **Database size:** 1-10MB (very portable)
- **RAM overhead:** <50MB idle, <100MB during retrieval

## Example Flow

```
User: "What temperature does Catalina prefer at night?"

→ SHORT-TERM: Check last 20 turns (no recent context)

→ FTS5 SEARCH: "temperature", "prefer", "night"
  ✓ Found fact: "Catalina prefers 70F at night"
  ✓ use_count++ (now used 5 times)

→ ENTITY STATE: Pull climate.bus_thermostat
  ✓ Current: 72F, target 70F, heating mode

→ BUILD PROMPT:
  "You are Harvey...
   FACTS: Catalina prefers 70F at night
   STATE: Thermostat currently 72F, heating to 70F
   HISTORY: [last 2 turns]
   
   Human: What temperature does Catalina prefer at night?"

→ OLLAMA: Qwen2.5-1.5B responds
  "Catalina prefers 70F at night. Currently, the 
   thermostat is at 72F and heating down to the target."

→ SAVE TURN: Add Q&A to turns table
  ✓ If 30 turns reached, trigger summarization

→ PIPER TTS: Speak response
```

## Troubleshooting

**Database locked / read-only**
- Check permissions: `ls -l /opt/harvey/memory/`
- Should be writable by `root` or the docker user
- `chmod 666 /opt/harvey/memory/harvey.db`

**Memory not persisting**
- Check `/opt/harvey/memory/` directory exists and is writable
- Verify `harvey_memory.py` is running in router process
- Check logs: `tail -f /opt/harvey/logs/memory.log`

**Embeddings not loading**
- Run: `ollama pull nomic-embed-text`
- Verify Ollama running: `curl http://localhost:11434/api/tags`
- System falls back to FTS5 automatically if unavailable

**Database corruption**
- Restore from backup: `cp /opt/harvey/backups/harvey.db.YYYYMMDD /opt/harvey/memory/harvey.db`
- Or delete entirely and start fresh (1-hour warmup for new facts)

## Future Enhancements

- [ ] Multi-user support (separate fact namespaces per user)
- [ ] Graph-based relationships (entity connections)
- [ ] Emotion tracking (user mood from conversation)
- [ ] Explicit importance rating (user marks "important" facts)
- [ ] Cross-session analytics (usage patterns over time)
