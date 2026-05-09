# Dashboard

The dashboard is a static HTML page served by `dashboard/server.py`. It is
the operator's view onto every other component: bot, arena, book, and
setups.

URL: `http://localhost:8000` (default). Talks to the bot via the Python
server's proxy at `/api/bot/...`.

---

## Tabs

### Bot
- Live status (in-game, opponent, games-today, lockout).
- Recent games table (W/L/D, opponent rating, TC, setup name + hash).
- Per-game replay: chess board with move-by-move stepping; pulls from
  `logs/game_traces/<id>.jsonl`.
- Pause/resume, reload, change daily quota and TC subset.

### Arena
- Local match results vs Stockfish at fixed strength.
- One series per opponent (e.g. SF1500, SF1800).
- Triggered by Docker (Arena image) — does **not** run on the host.

### Setups
- List + edit + deploy `EngineConfig` JSON files.
- Editor is auto-generated from `Cassandra.ENGINE_CONFIG_SCHEMA`.

### Book
- List of book positions and their candidate moves.
- Add a named line (UCI moves), delete entries, import the curated set.

### Docs
- This wiki. Loaded as Markdown from `dashboard/docs/*.md` and rendered
  client-side with [showdown](https://github.com/showdownjs/showdown).

---

## Where the data comes from

```
setups/
  *.json          ← user-editable setups
  deployed.json   ← active setup (single source of truth at runtime)
  history.jsonl   ← deploy audit trail

logs/
  bot_log.jsonl       ← one line per finished game
  bot_config.json     ← TC + matchmaking knobs (no engine settings)
  bot_quota.json      ← {date, count}
  arena_log.jsonl     ← arena match outcomes
  game_traces/<id>.jsonl ← per-move trace for the replay view

book/
  book.json     ← active book (hot-reloaded by bot)
  curated.json  ← seed set, importable from the dashboard
```

The dashboard server reads these files directly and proxies the bot's HTTP
control endpoints for live operations.

---

## Auth

If `DASHBOARD_SECRET` is set in the environment, every mutating API call
must carry `Authorization: Bearer <secret>`. The frontend prompts for the
secret on first load and stores it in `sessionStorage`. The static HTML and
Markdown docs are always served without auth (so the wiki is shareable).
