"""
    Cassandra

A classical alpha-beta chess engine in Julia, built on Bobby.jl move
generation. No neural networks: hand-crafted PeSTO eval, transposition
table, killers/history, null-move, LMR, aspiration windows, opening book.

Module wiring is strictly bottom-up:

    Board → Config → Eval → Search → Book

The exported surface is the only API the bot, UCI driver, arena, and
tests should depend on.
"""
module Cassandra

using Bobby
using JSON3
using Random

# ── Core position ────────────────────────────────────────────────────────────
include("Board.jl")

# ── Engine config (single source of truth for tunable knobs) ────────────────
include("Config.jl")

# ── Evaluation ───────────────────────────────────────────────────────────────
include("Eval/Classical.jl")

# ── Search ───────────────────────────────────────────────────────────────────
include("Search/TT.jl")
include("Search/MoveOrder.jl")
include("Search/SEE.jl")
include("Search/TimeBudget.jl")
include("Search/AlphaBeta.jl")

# ── Opening book ─────────────────────────────────────────────────────────────
include("Book.jl")

# ── Public API ───────────────────────────────────────────────────────────────
# Position
export START_FEN, apply_moves

# Evaluation
export classical_eval

# Search / engine
export search, select_move, tt_clear!, compute_budget_ms

# Engine config
export EngineConfig, SearchConfig, EvalConfig, OrderingConfig, BookConfig
export get_engine_cfg, apply_engine_cfg!, load_engine_cfg, save_engine_cfg
export engine_cfg_to_dict, engine_cfg_from_dict, cfg_hash, ENGINE_CONFIG_SCHEMA
export set_max_depth!, get_max_depth   # UCI shims

# Opening book
export Book

end # module Cassandra
