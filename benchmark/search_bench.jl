# Search benchmark for Cassandra.
#
# Run with:
#   julia --project=benchmark --check-bounds=no -O3 benchmark/search_bench.jl
#
# Measures:
#   - Bobby move-gen NPS via getMoves (the path search actually uses).
#   - classical_eval throughput.
#   - Full search NPS at fixed depth on a set of standard positions.
#   - Allocation pressure per search.
#   - A breakdown vs Bobby's perft to expose the search overhead multiplier.

using BenchmarkTools
using Bobby
using Cassandra
using Printf

# ── Helpers ───────────────────────────────────────────────────────────────────

function format_int(n::Int)
    s = string(n); buf = IOBuffer()
    for (i, c) in enumerate(reverse(s))
        i > 1 && (i - 1) % 3 == 0 && write(buf, ',')
        write(buf, c)
    end
    String(reverse(take!(buf)))
end

format_nps(x::Real) = format_int(round(Int, x))

# ── Standard positions ───────────────────────────────────────────────────────

const POSITIONS = [
    ("Starting position", ""),
    ("Kiwipete",          "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 0"),
    ("Position 3",        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"),
    ("Position 4",        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"),
    ("Position 5",        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"),
    ("Position 6",        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"),
]

board(fen) = isempty(fen) ? Bobby.setBoard() : Bobby.loadFen(fen)

# ── Microbenchmarks: per-call costs of the search building blocks ────────────

println("─── Microbenchmarks (per single call) ───────────────────────────────")
println()
@printf("%-30s  %12s  %12s  %12s\n", "Op", "median (ns)", "allocs", "bytes")
println("-"^76)

let b = board("")
    t = @benchmark Bobby.getMoves($b, $(b.active)) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Bobby.getMoves (startpos)",
        median(t).time, t.allocs, t.memory)
end

let b = board("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 0")
    t = @benchmark Bobby.getMoves($b, $(b.active)) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Bobby.getMoves (kiwipete)",
        median(t).time, t.allocs, t.memory)
end

let b = board("")
    t = @benchmark Bobby.inCheck($b, $(b.active)) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Bobby.inCheck",
        median(t).time, t.allocs, t.memory)
end

let b = board("")
    moves = Bobby.getMoves(b, b.active)
    m = moves.moves[1]
    t = @benchmark Bobby.makeMove($b, $m) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Bobby.makeMove (one ply)",
        median(t).time, t.allocs, t.memory)
end

let b = board("")
    t = @benchmark Cassandra.classical_eval($b) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Cassandra.classical_eval",
        median(t).time, t.allocs, t.memory)
end

let b = board("")
    t = @benchmark Bobby.computeHash($b) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Bobby.computeHash (full)",
        median(t).time, t.allocs, t.memory)
end

# Estimate the cost of just the legal-move generation in Bobby's perft path,
# by running perft d=1 (one node, generates + makes/unmakes children).
let b = board("")
    t = @benchmark Bobby.perft($b, 1) seconds=2
    @printf("%-30s  %12d  %12d  %12d\n",
        "Bobby.perft d=1 (1 node)",
        median(t).time, t.allocs, t.memory)
end

println()

# ── Search benchmarks ─────────────────────────────────────────────────────────
# Run a fixed-depth search on each position, count nodes and time.

println("─── Cassandra search NPS at fixed depth ─────────────────────────────")
println()

# Use a permissive config so all the heuristics are on (the realistic setting).
cfg = Cassandra.get_engine_cfg()
# Force full depth (not time-bounded) by giving an enormous time budget.
cfg.search.time_limit_s = 600.0

function search_nps(b, depth)
    # Disable the book — we want raw search work.
    cfg = Cassandra.get_engine_cfg()
    cfg.book.enabled = false
    cfg.search.max_depth = depth
    cfg.search.time_limit_s = 600.0
    Cassandra.tt_clear!()
    # Warmup
    Cassandra.search(b)
    Cassandra.tt_clear!()

    # Time it. Single trial — search at fixed depth is deterministic and slow,
    # @benchmark loops would balloon runtime. Repeat a few times for stability.
    t_best = Inf
    nodes_seen = 0
    for _ in 1:3
        Cassandra.tt_clear!()
        t0 = time_ns()
        # Reach into the internals: we need the node count.
        # The cleanest path: re-run search but read ctx via a wrapper.
        # The public `search` does not return nodes; we instrument via the
        # _negamax counter which lives in SearchContext per call.
        # Easiest: time `search` and use the `Cassandra._global_nodes` if any.
        Cassandra.search(b)
        elapsed = (time_ns() - t0) / 1e9
        t_best = min(t_best, elapsed)
    end
    return t_best
end

# We cannot read nodes from `search` directly without poking internals.
# Instead, implement a thin instrumented search that calls _negamax directly
# and reports nodes via SearchContext.
#
# Use Cassandra's exported pieces; for nodes we reach into the module.
const _negamax = getfield(Cassandra, :_negamax)
const SearchContext = getfield(Cassandra, :SearchContext)
const reset_ctx! = getfield(Cassandra, :reset_ctx!)
const INF_SCORE = getfield(Cassandra, :INF_SCORE)

function instrumented_search(b, depth)
    cfg = Cassandra.get_engine_cfg()
    cfg.book.enabled = false
    cfg.search.max_depth = depth
    cfg.search.time_limit_s = 600.0
    Cassandra.tt_clear!()
    ctx = SearchContext()
    seen = Set{UInt64}()
    deadline = time() + 600.0
    # Warmup
    _negamax(b, depth, -INF_SCORE, INF_SCORE, 0, deadline, seen, ctx, cfg)
    # Measure
    t_best = Inf
    nodes_best = 0
    for _ in 1:3
        Cassandra.tt_clear!()
        ctx2 = SearchContext()
        seen2 = Set{UInt64}()
        deadline = time() + 600.0
        t0 = time_ns()
        _negamax(b, depth, -INF_SCORE, INF_SCORE, 0, deadline, seen2, ctx2, cfg)
        elapsed = (time_ns() - t0) / 1e9
        if elapsed < t_best
            t_best = elapsed
            nodes_best = ctx2.nodes
        end
    end
    return t_best, nodes_best
end

@printf("%-22s  %5s  %14s  %10s  %12s\n", "Position", "Depth", "Nodes", "Time (s)", "NPS")
println("-"^72)

# Pick depth per position to keep total runtime manageable.
const SEARCH_DEPTHS = Dict(
    "Starting position" => 6,
    "Kiwipete"          => 5,
    "Position 3"        => 6,
    "Position 4"        => 5,
    "Position 5"        => 5,
    "Position 6"        => 5,
)

global total_nodes = 0
global total_time  = 0.0
for (name, fen) in POSITIONS
    b = board(fen)
    d = SEARCH_DEPTHS[name]
    t, n = instrumented_search(b, d)
    nps = n / t
    @printf("%-22s  d%-4d  %14s  %10.3f  %12s\n",
        name, d, format_int(n), t, format_nps(nps))
    global total_nodes += n
    global total_time  += t
end

println("-"^72)
@printf("%-22s        %14s  %10.3f  %12s\n",
    "TOTAL", format_int(total_nodes), total_time,
    format_nps(total_nodes / total_time))

println()

# ── Realistic time-bounded search (what the bot actually does) ──────────────

println("─── Time-bounded search (3 s budget, bot-realistic config) ──────────")
println()

@printf("%-22s  %10s  %14s  %12s\n", "Position", "Depth reached", "Nodes", "NPS")
println("-"^64)

for (name, fen) in POSITIONS
    b = board(fen)
    cfg = Cassandra.get_engine_cfg()
    cfg.book.enabled = false
    cfg.search.max_depth = 64
    cfg.search.time_limit_s = 3.0
    Cassandra.tt_clear!()

    # Warmup
    Cassandra.search(b)

    Cassandra.tt_clear!()
    ctx = SearchContext()
    seen = Set{UInt64}()
    deadline = time() + 3.0
    t0 = time_ns()
    # Run a real iterative-deepening search by calling `search` and timing,
    # but we still want the node count. Use _negamax directly with the same
    # iterative-deepening structure.
    nodes = 0
    depth_reached = 0
    for d in 1:cfg.search.max_depth
        time() > deadline && break
        ctx_d = SearchContext()
        seen_d = Set{UInt64}()
        _negamax(b, d, -INF_SCORE, INF_SCORE, 0, deadline, seen_d, ctx_d, cfg)
        if time() <= deadline
            depth_reached = d
            nodes += ctx_d.nodes
        else
            break
        end
    end
    elapsed = (time_ns() - t0) / 1e9
    nps = nodes / elapsed
    @printf("%-22s  d%-9d  %14s  %12s\n",
        name, depth_reached, format_int(nodes), format_nps(nps))
end

println()

# ── Ablation: which features cost what ───────────────────────────────────────
# Same position + depth, toggle one knob at a time, measure NPS.

println("─── Ablation (Starting position, fixed d=6) ─────────────────────────")
println()

const ABLATIONS = [
    ("baseline (all on)",         () -> nothing),
    ("no qsearch",                () -> Cassandra.get_engine_cfg().search.qsearch = false),
    ("no check_extension",        () -> Cassandra.get_engine_cfg().search.check_extension = false),
    ("no null_move",              () -> Cassandra.get_engine_cfg().search.null_move_enabled = false),
    ("no LMR",                    () -> Cassandra.get_engine_cfg().search.lmr_enabled = false),
    ("no aspiration",             () -> Cassandra.get_engine_cfg().search.aspiration_window_cp = 0),
    ("no killers",                () -> Cassandra.get_engine_cfg().ordering.killers = false),
    ("no history",                () -> Cassandra.get_engine_cfg().ordering.history = false),
    ("everything off",            () -> begin
        c = Cassandra.get_engine_cfg()
        c.search.qsearch = false
        c.search.check_extension = false
        c.search.null_move_enabled = false
        c.search.lmr_enabled = false
        c.search.aspiration_window_cp = 0
        c.ordering.killers = false
        c.ordering.history = false
    end),
]

@printf("%-30s  %12s  %12s  %12s\n", "Configuration", "Nodes", "Time (s)", "NPS")
println("-"^72)

let b = board("")
    for (label, mutator) in ABLATIONS
        # Reset to defaults
        Cassandra.apply_engine_cfg!(Cassandra.EngineConfig())
        cfg = Cassandra.get_engine_cfg()
        cfg.book.enabled = false
        cfg.search.max_depth = 6
        cfg.search.time_limit_s = 600.0
        mutator()
        Cassandra.tt_clear!()
        # Warmup
        ctx0 = SearchContext(); seen0 = Set{UInt64}()
        _negamax(b, 6, -INF_SCORE, INF_SCORE, 0, time()+600.0, seen0, ctx0, cfg)

        # Measure
        t_best = Inf; n_best = 0
        for _ in 1:3
            Cassandra.tt_clear!()
            ctx = SearchContext(); seen = Set{UInt64}()
            t0 = time_ns()
            _negamax(b, 6, -INF_SCORE, INF_SCORE, 0, time()+600.0, seen, ctx, cfg)
            el = (time_ns() - t0) / 1e9
            if el < t_best; t_best = el; n_best = ctx.nodes; end
        end
        @printf("%-30s  %12s  %12.3f  %12s\n",
            label, format_int(n_best), t_best, format_nps(n_best/t_best))
    end
end

# Restore defaults
Cassandra.apply_engine_cfg!(Cassandra.EngineConfig())

println()

# ── Comparison: perft vs search at the same depth ────────────────────────────
# Highlights the per-node overhead the search adds on top of pure move gen.

println("─── Search-vs-perft node-cost ratio (Starting position) ─────────────")
println()

let b = board("")
    cfg = Cassandra.get_engine_cfg()
    cfg.book.enabled = false
    cfg.search.time_limit_s = 600.0

    @printf("%-7s  %14s  %14s  %12s  %12s  %8s\n",
        "Depth", "perft nodes", "search nodes", "perft NPS", "search NPS", "ratio")
    println("-"^78)
    for d in 3:6
        # perft
        Bobby.perft(b, min(d, 3))  # warmup
        t_perft = @elapsed pt = Bobby.perft(b, d)
        perft_nodes = pt.nodes[d]
        perft_nps = perft_nodes / t_perft

        # search
        cfg.search.max_depth = d
        Cassandra.tt_clear!()
        ctx0 = SearchContext(); seen0 = Set{UInt64}()
        _negamax(b, d, -INF_SCORE, INF_SCORE, 0, time()+600.0, seen0, ctx0, cfg)
        Cassandra.tt_clear!()
        ctx = SearchContext(); seen = Set{UInt64}()
        t_search = @elapsed _negamax(b, d, -INF_SCORE, INF_SCORE, 0, time()+600.0, seen, ctx, cfg)
        search_nps = ctx.nodes / t_search
        @printf("d%-6d  %14s  %14s  %12s  %12s  %7.1fx\n",
            d, format_int(perft_nodes), format_int(ctx.nodes),
            format_nps(perft_nps), format_nps(search_nps), perft_nps/search_nps)
    end
end

println()
println("Done.")
