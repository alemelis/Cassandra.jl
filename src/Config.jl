Base.@kwdef mutable struct SearchConfig
    max_depth::Int          = 12
    time_limit_s::Float64   = 3.0
    tt_size_log2::Int       = 20

    qsearch::Bool           = true
    delta_pruning_margin_cp::Int = 200

    check_extension::Bool   = true

    null_move_enabled::Bool = true
    null_move_R::Int        = 2
    null_move_min_depth::Int = 3

    lmr_enabled::Bool       = true
    lmr_min_depth::Int      = 3
    lmr_min_move_idx::Int   = 4
    lmr_reduction::Int      = 1

    aspiration_window_cp::Int = 50

    # SEE-based capture filtering in qsearch. Captures with see < threshold
    # are skipped. Default 0 prunes hopeless captures only; negative values
    # accept slightly losing captures (useful for tactical personalities).
    see_qsearch_threshold_cp::Int = 0

    # Adaptive time control. The bot supplies remaining_ms / increment_ms
    # per move (Lichess clock); `time_strategy` picks how to slice them.
    # `time_limit_s` above remains the fallback when the bot can't supply
    # a clock (offline tools, benchmarks, correspondence games).
    time_strategy::String         = "phase_weighted"   # "fixed"|"linear"|"phase_weighted"
    time_panic_threshold_ms::Int  = 10_000             # below this → panic mode
    time_min_ms::Int              = 50                 # never search less than this
    time_max_ms::Int              = 3_000              # hard cap even with big clocks
    time_critical_bonus::Float64  = 1.3                # ×budget when in check
end

Base.@kwdef mutable struct EvalConfig
    bishop_pair_cp::Int  = 40
    rook_open_cp::Int    = 25
    rook_semi_cp::Int    = 12
end

Base.@kwdef mutable struct OrderingConfig
    killers::Bool = true
    history::Bool = true
end

Base.@kwdef mutable struct BookConfig
    enabled::Bool   = true
    path::String    = ""        # polyglot .bin path; empty = no book
    chaos::Float64  = 0.0       # 0 = mainline weighted sampling; 1 = uniform
    max_ply::Int    = 20        # ignore book past this ply
end

Base.@kwdef mutable struct EngineConfig
    name::String       = "default"
    created_at::String = ""

    search::SearchConfig     = SearchConfig()
    eval::EvalConfig         = EvalConfig()
    ordering::OrderingConfig = OrderingConfig()
    book::BookConfig         = BookConfig()
end

# JSON schema for dashboard editor (field → description + constraints)
const ENGINE_CONFIG_SCHEMA = Dict{String,Any}(
    "search.max_depth"             => Dict("type"=>"int",   "min"=>1,  "max"=>64,   "step"=>1,   "description"=>"Maximum search depth (plies). Higher = stronger but slower.", "doc"=>"search.md#iterative-deepening"),
    "search.time_limit_s"          => Dict("type"=>"float", "min"=>0.1,"max"=>60.0, "step"=>0.1, "description"=>"Time budget per move in seconds.", "doc"=>"search.md#iterative-deepening"),
    "search.tt_size_log2"          => Dict("type"=>"int",   "min"=>16, "max"=>26,   "step"=>1,   "description"=>"Transposition table size = 2^N entries (~32MB at N=20).", "doc"=>"search.md#transposition-table"),
    "search.qsearch"               => Dict("type"=>"bool",  "description"=>"Enable quiescence search to resolve captures at leaf nodes, preventing the horizon effect.", "doc"=>"search.md#quiescence-search"),
    "search.delta_pruning_margin_cp" => Dict("type"=>"int", "min"=>0,  "max"=>500,  "step"=>10,  "description"=>"Delta pruning margin (cp). Captures that can't bring score within this margin of alpha are skipped in qsearch.", "doc"=>"search.md#quiescence-search"),
    "search.check_extension"       => Dict("type"=>"bool",  "description"=>"Extend search by one ply when the side to move is in check.", "doc"=>"search.md#check-extension"),
    "search.null_move_enabled"     => Dict("type"=>"bool",  "description"=>"Enable null-move pruning. If passing the move still fails high, prune. Disabled automatically in pawn endgames.", "doc"=>"search.md#null-move-pruning"),
    "search.null_move_R"           => Dict("type"=>"int",   "min"=>1,  "max"=>4,    "step"=>1,   "description"=>"Null-move reduction depth R (search depth-1-R after null move).", "doc"=>"search.md#null-move-pruning"),
    "search.null_move_min_depth"   => Dict("type"=>"int",   "min"=>1,  "max"=>6,    "step"=>1,   "description"=>"Minimum depth to attempt null-move pruning.", "doc"=>"search.md#null-move-pruning"),
    "search.lmr_enabled"           => Dict("type"=>"bool",  "description"=>"Enable Late Move Reductions. Quiet moves searched late in the list are reduced.", "doc"=>"search.md#late-move-reductions"),
    "search.lmr_min_depth"         => Dict("type"=>"int",   "min"=>1,  "max"=>6,    "step"=>1,   "description"=>"Minimum depth to apply LMR.", "doc"=>"search.md#late-move-reductions"),
    "search.lmr_min_move_idx"      => Dict("type"=>"int",   "min"=>1,  "max"=>10,   "step"=>1,   "description"=>"Move index (1-based) after which LMR kicks in.", "doc"=>"search.md#late-move-reductions"),
    "search.lmr_reduction"         => Dict("type"=>"int",   "min"=>1,  "max"=>3,    "step"=>1,   "description"=>"Ply reduction applied to late moves under LMR.", "doc"=>"search.md#late-move-reductions"),
    "search.aspiration_window_cp"  => Dict("type"=>"int",   "min"=>0,  "max"=>200,  "step"=>10,  "description"=>"Initial aspiration window around previous iteration score (cp). 0 = full window.", "doc"=>"search.md#aspiration-windows"),
    "search.see_qsearch_threshold_cp" => Dict("type"=>"int", "min"=>-300, "max"=>300, "step"=>10, "description"=>"SEE threshold for qsearch capture pruning (cp). Captures with SEE below this are skipped. 0 = prune hopeless only; negative accepts slight losers (tactical personalities).", "doc"=>"search.md#quiescence-search"),
    "search.time_strategy"          => Dict("type"=>"enum", "options"=>["fixed","linear","phase_weighted"], "description"=>"How to allocate per-move time from the Lichess clock. phase_weighted spends most in the middlegame; linear is classical remaining/N+inc; fixed uses time_limit_s.", "doc"=>"search.md#time-control"),
    "search.time_panic_threshold_ms" => Dict("type"=>"int", "min"=>1000, "max"=>120000, "step"=>500, "description"=>"Remaining clock (ms) below which panic mode engages — overrides the chosen strategy with a tiny per-move slice.", "doc"=>"search.md#time-control"),
    "search.time_min_ms"             => Dict("type"=>"int", "min"=>10,   "max"=>5000,   "step"=>10,  "description"=>"Minimum per-move search budget (ms).", "doc"=>"search.md#time-control"),
    "search.time_max_ms"             => Dict("type"=>"int", "min"=>100,  "max"=>60000,  "step"=>100, "description"=>"Maximum per-move search budget (ms). Hard cap even with big clocks.", "doc"=>"search.md#time-control"),
    "search.time_critical_bonus"     => Dict("type"=>"float", "min"=>1.0, "max"=>3.0,   "step"=>0.1, "description"=>"Multiplier applied to the budget on critical positions (currently: when in check).", "doc"=>"search.md#time-control"),
    "eval.bishop_pair_cp"          => Dict("type"=>"int",   "min"=>0,  "max"=>100,  "step"=>5,   "description"=>"Bonus for having both bishops (centipawns).", "doc"=>"eval.md#bishop-pair"),
    "eval.rook_open_cp"            => Dict("type"=>"int",   "min"=>0,  "max"=>80,   "step"=>5,   "description"=>"Bonus for rook on fully open file (no pawns of either side).", "doc"=>"eval.md#rook-open-file"),
    "eval.rook_semi_cp"            => Dict("type"=>"int",   "min"=>0,  "max"=>50,   "step"=>5,   "description"=>"Bonus for rook on semi-open file (no own pawns).", "doc"=>"eval.md#rook-open-file"),
    "ordering.killers"             => Dict("type"=>"bool",  "description"=>"Use killer move heuristic: prefer quiet moves that caused beta-cutoffs at the same depth.", "doc"=>"search.md#move-ordering"),

    "ordering.history"             => Dict("type"=>"bool",  "description"=>"Use history heuristic: prefer quiet moves with good historical cutoff record.", "doc"=>"search.md#move-ordering"),
    "book.enabled"                 => Dict("type"=>"bool",  "description"=>"Enable opening book lookups.", "doc"=>"search.md#opening-book"),
    "book.path"                    => Dict("type"=>"string","description"=>"Path to a polyglot .bin opening book. Loaded at startup; empty = no book.", "doc"=>"search.md#opening-book"),
    "book.chaos"                   => Dict("type"=>"float", "min"=>0.0, "max"=>1.0, "step"=>0.05, "description"=>"Sampling chaos: 0.0 = mainline (weight-proportional), 1.0 = uniform across all book entries for the position.", "doc"=>"search.md#opening-book"),
    "book.max_ply"                 => Dict("type"=>"int",   "min"=>0,  "max"=>40,   "step"=>2,   "description"=>"Maximum ply at which to consult the book.", "doc"=>"search.md#opening-book"),
)

# ── Global live config ───────────────────────────────────────────────────────
const _ENGINE_CFG = Ref(EngineConfig())

get_engine_cfg() = _ENGINE_CFG[]

# Compatibility shims (bot control server and tests call these)
set_max_depth!(d::Integer) = (_ENGINE_CFG[].search.max_depth = clamp(Int(d), 1, 64))
get_max_depth()            = _ENGINE_CFG[].search.max_depth

function apply_engine_cfg!(cfg::EngineConfig)
    _ENGINE_CFG[] = cfg
end

# ── JSON serialisation helpers ───────────────────────────────────────────────
function engine_cfg_to_dict(cfg::EngineConfig)::Dict{String,Any}
    s = cfg.search; e = cfg.eval; o = cfg.ordering; b = cfg.book
    Dict{String,Any}(
        "name"       => cfg.name,
        "created_at" => cfg.created_at,
        "search" => Dict{String,Any}(
            "max_depth"              => s.max_depth,
            "time_limit_s"           => s.time_limit_s,
            "tt_size_log2"           => s.tt_size_log2,
            "qsearch"                => s.qsearch,
            "delta_pruning_margin_cp"=> s.delta_pruning_margin_cp,
            "check_extension"        => s.check_extension,
            "null_move_enabled"      => s.null_move_enabled,
            "null_move_R"            => s.null_move_R,
            "null_move_min_depth"    => s.null_move_min_depth,
            "lmr_enabled"            => s.lmr_enabled,
            "lmr_min_depth"          => s.lmr_min_depth,
            "lmr_min_move_idx"       => s.lmr_min_move_idx,
            "lmr_reduction"          => s.lmr_reduction,
            "aspiration_window_cp"   => s.aspiration_window_cp,
            "see_qsearch_threshold_cp" => s.see_qsearch_threshold_cp,
            "time_strategy"            => s.time_strategy,
            "time_panic_threshold_ms"  => s.time_panic_threshold_ms,
            "time_min_ms"              => s.time_min_ms,
            "time_max_ms"              => s.time_max_ms,
            "time_critical_bonus"      => s.time_critical_bonus,
        ),
        "eval" => Dict{String,Any}(
            "bishop_pair_cp" => e.bishop_pair_cp,
            "rook_open_cp"   => e.rook_open_cp,
            "rook_semi_cp"   => e.rook_semi_cp,
        ),
        "ordering" => Dict{String,Any}(
            "killers" => o.killers,
            "history" => o.history,
        ),
        "book" => Dict{String,Any}(
            "enabled" => b.enabled,
            "path"    => b.path,
            "chaos"   => b.chaos,
            "max_ply" => b.max_ply,
        ),
    )
end

function engine_cfg_from_dict(d::Dict)::EngineConfig
    _d(v) = v isa AbstractDict ? v : Dict{String,Any}()
    s = _d(get(d, "search",   nothing))
    e = _d(get(d, "eval",     nothing))
    o = _d(get(d, "ordering", nothing))
    b = _d(get(d, "book",     nothing))
    _s(v, def) = v isa AbstractString ? v : def
    EngineConfig(
        name       = _s(get(d, "name",       nothing), "default"),
        created_at = _s(get(d, "created_at", nothing), ""),
        search = SearchConfig(
            max_depth               = get(s, "max_depth",               12),
            time_limit_s            = get(s, "time_limit_s",            3.0),
            tt_size_log2            = get(s, "tt_size_log2",            20),
            qsearch                 = get(s, "qsearch",                 true),
            delta_pruning_margin_cp = get(s, "delta_pruning_margin_cp", 200),
            check_extension         = get(s, "check_extension",         true),
            null_move_enabled       = get(s, "null_move_enabled",       true),
            null_move_R             = get(s, "null_move_R",             2),
            null_move_min_depth     = get(s, "null_move_min_depth",     3),
            lmr_enabled             = get(s, "lmr_enabled",             true),
            lmr_min_depth           = get(s, "lmr_min_depth",           3),
            lmr_min_move_idx        = get(s, "lmr_min_move_idx",        4),
            lmr_reduction           = get(s, "lmr_reduction",           1),
            aspiration_window_cp    = get(s, "aspiration_window_cp",    50),
            see_qsearch_threshold_cp = get(s, "see_qsearch_threshold_cp", 0),
            time_strategy            = string(get(s, "time_strategy", "phase_weighted")),
            time_panic_threshold_ms  = Int(get(s, "time_panic_threshold_ms", 10_000)),
            time_min_ms              = Int(get(s, "time_min_ms", 50)),
            time_max_ms              = Int(get(s, "time_max_ms", 3_000)),
            time_critical_bonus      = Float64(get(s, "time_critical_bonus", 1.3)),
        ),
        eval = EvalConfig(
            bishop_pair_cp = get(e, "bishop_pair_cp", 40),
            rook_open_cp   = get(e, "rook_open_cp",   25),
            rook_semi_cp   = get(e, "rook_semi_cp",   12),
        ),
        ordering = OrderingConfig(
            killers = get(o, "killers", true),
            history = get(o, "history", true),
        ),
        book = BookConfig(
            enabled = get(b, "enabled", true),
            path    = string(get(b, "path",    "")),
            chaos   = Float64(get(b, "chaos",   0.0)),
            max_ply = Int(get(b, "max_ply", 20)),
        ),
    )
end

function load_engine_cfg(path::AbstractString)::EngineConfig
    isfile(path) || return EngineConfig()
    d = JSON3.read(read(path, String), Dict{String,Any})
    engine_cfg_from_dict(d)
end

function save_engine_cfg(cfg::EngineConfig, path::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.write(io, engine_cfg_to_dict(cfg))
    end
end

# Short stable hash of the config for log tagging
function cfg_hash(cfg::EngineConfig)::String
    d = engine_cfg_to_dict(cfg)
    h = hash(JSON3.write(d))
    string(h, base=16)[1:min(12, end)]
end
