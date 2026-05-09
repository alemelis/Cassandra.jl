# Bot

`bot/main.jl` runs Cassandra on Lichess. It manages: matchmaking,
challenge handling, the per-game move loop, daily quota, lockouts, a small
HTTP control server, and hot-reloading of the deployed setup.

The core invariants:

- **One game at a time** (`IN_GAME` flag). Lichess allows more, but a single
  in-flight game keeps the search budget predictable.
- **Self-paced challenges.** The bot doesn't blast challenges; it spaces
  them so it lands close to `daily_quota` games per day.
- **Hot reload.** `/reload` re-reads `setups/deployed.json` and applies it
  immediately; the dashboard's Deploy button takes effect on the bot's next
  move with no restart (mid-game reloads resign the current game first).

---

## The move loop

```julia
function handle_position(client, game_id, fen, moves_str, my_color)
    board = Cassandra.apply_moves(moves_str, fen)
    is_my_turn || return
    move = Cassandra.select_move(board)
    BongCloud.make_move(client, game_id, move)
end
```

`select_move`:

1. If `book.enabled` and the position is in the book → return the book move.
2. Otherwise → `search(board; cfg=get_engine_cfg())`.

The deployed setup's `time_limit_s` bounds search time. There is **no
pondering** (search during the opponent's clock) — added complexity for
limited gain at our current strength.

Game traces (one JSON line per move) are written to
`logs/game_traces/<game_id>.jsonl`: ply, FEN-before, move, and the
opponent's reply. The dashboard's game replay reads these.

---

## Matchmaking (`matchmaker_loop`)

Self-paced loop:

```
sleep(pacing_interval)
if paused or in-game or quota-hit → continue
target = pick a random eligible online bot in rating window
clock  = pick a random enabled time control
issue challenge with TTL = 60s
```

`pacing_interval` divides the time remaining today by the games left in
quota — so if you have 50 games left and 10 hours, it sleeps ~12 minutes
between attempts. Hard floor of `min_challenge_gap_seconds` (default 60).

`pick_target` filters `BongCloud.get_online_bots` to bots whose rating is
within `[rating_low, rating_high]` of our own (negatives mean weaker). The
**skiplist** stores per-bot 24h cooldowns after a decline or error, so we
don't spam the same target.

**Lockout** — on HTTP 429 from Lichess, set a `LOCKOUT_UNTIL` timestamp; all
matchmaking and acceptance is paused until it elapses. Default 120 s; bumped
on repeated rate-limits.

---

## Time controls

The `TC_OPTIONS` list defines every TC the bot can challenge with:

| Label | Clock | Bucket |
|-------|-------|--------|
| 15s+0, 30s+0 | 15s, 30s, no inc | ultra-bullet |
| 1+0 to 3+0 | 60–180s, 0 inc | bullet |
| 3+2, 5+0, 5+3 | 180–300s | blitz |
| 10+0 to 15+10 | 600–900s + inc | rapid |

The dashboard writes a subset to `enabled_tcs` in `bot_config.json`. Each
challenge picks one at random. Restricting to a single TC (e.g. only "1+0")
is the right move when arena-tuning at a specific time control — it makes
the bot's published rating cleaner.

---

## Engine setup hot reload (`load_engine_setup!`)

On startup and every `/reload` POST:

```julia
cfg = Cassandra.load_engine_cfg("setups/deployed.json")
Cassandra.apply_engine_cfg!(cfg)
SETUP_META[] = {name, hash}
```

The setup file is the **single source of truth** at runtime.

If a `/reload` arrives mid-game, the current game is **resigned** (the
configuration may now be invalid for the in-flight position; cleaner to
forfeit than to play half a game with one config and half with another).
After the resign, the setup is reloaded for the next game.

---

## HTTP control server

Listens on `BOT_CONTROL_PORT` (default 8080). Endpoints:

| Method | Path | Purpose |
|--------|------|---------|
| GET  | `/status` | Live bot state (in-game, opponent, games today, …) |
| GET  | `/config` | Read-only TC + matchmaking config |
| POST | `/config` | Patch TC + matchmaking config |
| POST | `/pause`, `/resume` | Quick pause/resume |
| POST | `/reload` | Reload deployed setup (resigns current game) |
| GET  | `/health` | Liveness probe |
| GET  | `/engine_config` | Current `EngineConfig` as JSON |
| GET  | `/engine_config/schema` | The schema (for the editor UI) |
| POST | `/engine_config` | Apply + persist a new `EngineConfig` |
| GET  | `/book` | List book entries |
| POST | `/book/line` | Add a curated line |
| POST | `/book/entry/delete` | Remove one move from a position |
| POST | `/book/import` | Reload `curated.json` |
| POST | `/book/clear` | Empty the book |

The dashboard's Python server proxies these (with optional `DASHBOARD_SECRET`
auth on top), so the bot doesn't need to be exposed publicly.

---

## Daily quota

`bot_quota.json` tracks `{date, count}`. `increment_quota!` bumps the count
on every accepted/started game. `quota_reached()` blocks new challenges and
declines incoming ones with `reason="later"` once the daily limit hits.

Resets at local midnight (`today()`).

---

## What about UCI?

`bot/uci.jl` exists for running Cassandra under Stockfish-style GUIs (and is
how the arena vs Stockfish runs work — Cassandra speaks UCI to a referee
inside Docker). It is a simpler loop: read commands from stdin, dispatch
`go`/`position`/`isready`/`quit`. Same `select_move` underneath.
