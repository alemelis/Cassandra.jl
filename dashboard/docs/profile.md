# Profile

The **Profile** tab runs Cassandra's `search()` on a single position inside a Docker container and renders the result as an interactive flame graph.

## How it works

1. Pick a preset position (or paste a custom FEN) and a time budget (seconds).
2. Click **Run** — a container starts, pre-warms the JIT, then samples `search()` with Julia's built-in `Profile` stdlib at 1 kHz.
3. When sampling finishes, the container writes two files to `logs/profile/`:
   - `<ts>.collapsed` — Brendan-Gregg-style stacks (`root;parent;leaf count`).
   - `<ts>.meta.json` — metadata (samples, truncated flag, setup name, …).
4. The run appears in the **Runs** table. Tap a row to load the flame graph.

## Reading the flame graph

- **Root is at the bottom**, leaves at the top (icicle / bottom-up layout). Hot leaf functions appear at eye level.
- **Width = time**. A wider bar spent more samples in that function.
- **Tap to zoom** into any frame. Tap **↑** to zoom back out one level.
- **Filter** field highlights matching frames in red and shows "N% of samples match" — useful for measuring impact (`_qsearch`, `getMoves`, etc.).
- **Show C frames** toggle reveals Julia runtime and GC internals (hidden by default).
- Frames narrower than 4 px are aggregated into a `(N others)` placeholder to avoid visual noise on mobile.

## Positions

| Preset | Description |
|---|---|
| Starting position | `rnbqkbnr/pppppppp/…` |
| Kiwipete | Rich tactical position, good for move-generation profiling |
| Middlegame | Balanced open game |
| Endgame (KP-K) | King+Pawn ending; exercises endgame eval and quiescence |
| Custom FEN | Paste any valid FEN |

## Notes

- The profile uses the currently **deployed setup** (`setups/deployed.json`) so knobs like `max_depth` and hash-table size reflect what the bot actually uses.
- `max_depth` is overridden to 64 and the opening book is disabled so `SECONDS` is the binding constraint, not depth.
- If the container is killed mid-run (e.g. you click **Stop**), a partial profile is flushed and tagged `partial: true` in the metadata.
- Runs are stored indefinitely; delete them with the **del** button in the table.
