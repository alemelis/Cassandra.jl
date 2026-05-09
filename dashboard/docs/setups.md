# Engine setups

A **setup** is a named JSON file that fully defines how Cassandra plays:
search depth, evaluation bonuses, move-ordering heuristics, and book usage.
Every game played is tagged with the active setup's name and short hash, so
any result in `bot_log.jsonl` can be traced back to the exact configuration.

Conceptually: a setup is the engine's deployable unit. Tuning happens by
cloning a setup, flipping one knob, deploying, and comparing arena win rates
between the two `setup_hash` values.

`setups/deployed.json` is the **single source of truth** for engine knobs at
runtime. The bot reads it on start and on every `/reload`.

---

## What's in a setup

```json
{
  "name": "classical_v1",
  "created_at": "2026-05-08T19:00:00Z",

  "search": {
    "max_depth": 12,
    "time_limit_s": 3.0,
    "tt_size_log2": 20,
    "qsearch": true,
    "delta_pruning_margin_cp": 200,
    "check_extension": true,
    "null_move_enabled": true,
    "null_move_R": 2,
    "null_move_min_depth": 3,
    "lmr_enabled": true,
    "lmr_min_depth": 3,
    "lmr_min_move_idx": 4,
    "lmr_reduction": 1,
    "aspiration_window_cp": 50
  },

  "eval": {
    "bishop_pair_cp": 40,
    "rook_open_cp": 25,
    "rook_semi_cp": 12
  },

  "ordering": {
    "killers": true,
    "history": true
  },

  "book": { "enabled": true, "max_ply": 16 }
}
```

The full schema with min/max ranges, defaults, and per-field documentation
links is in `Cassandra.ENGINE_CONFIG_SCHEMA` (`src/Config.jl`). The
dashboard's setup editor is generated from that schema, so adding a knob in
`SearchConfig` + a row in the schema is enough — no UI changes needed.

---

## Lifecycle

### Create
Click **Create** in the Setups panel to start from scratch or clone the
active setup. Setups are saved as `setups/<name>.json`. Names are
auto-generated (`tactical_morphy`, `prophylactic_capablanca`, …) but you can
override before clicking Create.

### Edit
Fields are grouped by section (Search / Eval / Ordering / Book). Each field
shows a short tooltip; clicking the **?** opens the relevant wiki page at
the right anchor.

### Save / Save as…
**Save** overwrites the current file. **Save as…** clones to a new name,
useful for "branch and tweak" experiments without touching the original.

### Deploy
**Deploy** copies the setup to `setups/deployed.json` and signals the bot
to reload via the `/reload` HTTP endpoint. The bot picks up the new config
on its next move — no restart. Every deploy is appended to
`setups/history.jsonl` as an audit trail.

### Delete
Setups can't be deleted while deployed. Deploy a different one first, or
rename.

---

## Audit trail

`setups/history.jsonl`:

```json
{"ts":"2026-05-08T19:05:00Z","name":"classical_v1_lmr"}
{"ts":"2026-05-08T20:30:00Z","name":"classical_v1_nolmr"}
```

`logs/bot_log.jsonl` per game:

```json
{"ts":"...","game_id":"abc","result":"win",
 "setup_name":"classical_v1","setup_hash":"a3f8c2e1d09b"}
```

Group by `setup_hash` to compare configurations:

```bash
jq -r '[.setup_hash, .result] | @tsv' logs/bot_log.jsonl \
  | sort | uniq -c | sort -rn
```

---

## How `cfg_hash` works

```julia
function cfg_hash(cfg)
    d = engine_cfg_to_dict(cfg)
    h = hash(JSON3.write(d))
    string(h, base=16)[1:12]
end
```

Stable across serialisations of the same config — JSON3.write produces
field-order-stable output for the schema-typed dict. So two setups with
identical knob values get the same hash even if their `name` or `created_at`
differ.

This means: the hash uniquely identifies the *behaviour*, not the file. Use
`name` to trace which file you saved; use `setup_hash` to ask "did this
sample of games come from the same engine?"

---

## Tuning workflow

1. Clone the deployed setup.
2. Change one knob (e.g. `null_move_R: 2 → 3`).
3. Deploy.
4. Run an arena session (Arena tab → "Run vs Stockfish 1500" or similar).
5. Wait for ≥ 30 games.
6. Compare win rates by `setup_hash` in the bot log (or in the arena log).
7. If decisive, keep the change and reset; otherwise revert by re-deploying
   the previous setup from `history.jsonl`.

The Elo difference detectable from N games is roughly `400 / √N`. So 30
games → ±70 Elo (noisy), 200 games → ±28 Elo, 1000 games → ±13 Elo. For
small ablations (single-knob changes worth +10 Elo), you need hundreds of
games per arm to be sure.

---

## Tips

- **Time vs depth.** `time_limit_s` *and* `max_depth` are both upper bounds;
  whichever fires first wins. For arena testing set `time_limit_s` to a
  match your TC; for analysis set `max_depth` to a fixed value and
  `time_limit_s` to a large number.
- **TT resize.** Changing `tt_size_log2` requires a bot restart — the
  global `_TT` is sized at module load.
