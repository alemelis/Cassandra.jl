# Adaptive per-move time-budget strategies.
#
# Called by the bot on every move with the current Lichess clock state.
# Returns milliseconds to allocate to *this* search. Returning 0 is the
# bot's signal that the move should come from a non-search source (book);
# the engine itself never gets a 0 budget.

# A "TimeContext" is just the inputs the strategies need. Kept as a flat
# NamedTuple so callers don't have to construct an object.
const TimeContext = NamedTuple{
    (:remaining_ms, :increment_ms, :moves_played, :phase, :in_check, :strategy),
    Tuple{Int, Int, Int, Int, Bool, String},
}

# ── Strategy implementations ─────────────────────────────────────────────────

@inline _clamp_budget(ms::Int, cfg::SearchConfig) =
    clamp(ms, cfg.time_min_ms, cfg.time_max_ms)

# Legacy fixed budget — ignores the clock, uses configured time_limit_s.
_budget_fixed(_::TimeContext, cfg::SearchConfig)::Int =
    round(Int, cfg.time_limit_s * 1000)

# Classical "remaining / N + a*inc" allocator.
function _budget_linear(t::TimeContext, cfg::SearchConfig)::Int
    moves_to_go = max(40 - t.moves_played, 20)
    ms = t.remaining_ms ÷ moves_to_go + (4 * t.increment_ms) ÷ 5
    return _clamp_budget(ms, cfg)
end

# Phase-weighted: spend less in known territory (book/opening exit), most
# in the middlegame, taper in endgame. Burns a critical-position bonus on
# checks. Phase is from `_game_phase` (24 = full pieces, 0 = bare kings).
function _budget_phase_weighted(t::TimeContext, cfg::SearchConfig)::Int
    base = if t.phase >= 20
        t.remaining_ms ÷ 50 + t.increment_ms ÷ 2
    elseif t.phase >= 10
        t.remaining_ms ÷ 25 + t.increment_ms
    else
        t.remaining_ms ÷ 30 + (4 * t.increment_ms) ÷ 5
    end
    t.in_check && (base = round(Int, base * cfg.time_critical_bonus))
    return _clamp_budget(base, cfg)
end

# Panic: time is short — spend a tiny fraction of what's left.
function _budget_panic(t::TimeContext, cfg::SearchConfig)::Int
    ms = t.remaining_ms ÷ 60
    return max(cfg.time_min_ms, min(ms, cfg.time_max_ms))
end

# ── Entry point ──────────────────────────────────────────────────────────────

"""
    compute_budget_ms(remaining_ms, increment_ms, board, cfg;
                      moves_played=0, in_check=false) -> Int

Returns the milliseconds to allocate to this move's search, given the
current clock and `cfg.search.time_strategy`. Engages panic mode
automatically when `remaining_ms ≤ cfg.search.time_panic_threshold_ms`,
regardless of the configured strategy.

Always returns a positive integer (clamped to [`time_min_ms`,
`time_max_ms`]). For book-hit "0ms" semantics, the bot short-circuits
this function entirely.
"""
function compute_budget_ms(remaining_ms::Integer, increment_ms::Integer,
                           board::Bobby.Board, cfg::EngineConfig;
                           moves_played::Integer = 0,
                           in_check::Bool = false)::Int
    scfg = cfg.search
    rem_ms = Int(remaining_ms)
    inc_ms = Int(increment_ms)
    # Guard: malformed inputs (correspondence games etc.) → use fixed budget.
    rem_ms <= 0 && return _budget_fixed(_dummy_ctx(scfg), scfg)

    in_panic = rem_ms <= scfg.time_panic_threshold_ms

    phase = _game_phase(board.white, board.black)
    ctx = (remaining_ms = rem_ms,
           increment_ms = inc_ms,
           moves_played = Int(moves_played),
           phase        = phase,
           in_check     = in_check,
           strategy     = scfg.time_strategy)

    in_panic && return _budget_panic(ctx, scfg)
    if scfg.time_strategy == "fixed"
        return _budget_fixed(ctx, scfg)
    elseif scfg.time_strategy == "linear"
        return _budget_linear(ctx, scfg)
    else  # "phase_weighted" or unknown → safe default
        return _budget_phase_weighted(ctx, scfg)
    end
end

# Placeholder context for the fixed-budget path when we never read the clock.
@inline _dummy_ctx(scfg::SearchConfig) = (
    remaining_ms = 0, increment_ms = 0, moves_played = 0,
    phase = 24, in_check = false, strategy = scfg.time_strategy,
)
