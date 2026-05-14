# Profile Cassandra search to identify make/unmake opportunity.
#
# Run with:
#   julia --project=benchmark --check-bounds=no -O3 benchmark/profile_search.jl
#
# Output: flat profile printed to stdout + saved to benchmark/profiles/<sha>.txt
# Interpretation guide is printed at the bottom.

using Profile
using Dates
using Bobby
using Cassandra
using Printf

const _negamax     = getfield(Cassandra, :_negamax)
const SearchContext = getfield(Cassandra, :SearchContext)
const INF_SCORE    = getfield(Cassandra, :INF_SCORE)

# ── Config ───────────────────────────────────────────────────────────────────

const PROFILE_FEN   = ""      # startpos
const PROFILE_DEPTH = 6       # deep enough to be representative
const PROFILE_REPS  = 5       # repeat inside profile window for sample density

function setup_cfg()
    cfg = Cassandra.get_engine_cfg()
    cfg.book.enabled  = false
    cfg.search.max_depth   = PROFILE_DEPTH
    cfg.search.time_limit_s = 600.0
    cfg
end

# ── Warmup ───────────────────────────────────────────────────────────────────

b = isempty(PROFILE_FEN) ? Bobby.setBoard() : Bobby.loadFen(PROFILE_FEN)

println("Warming up JIT (depth $(PROFILE_DEPTH), starting position)...")
cfg = setup_cfg()
Cassandra.tt_clear!()
ctx = SearchContext()
_negamax(b, PROFILE_DEPTH, -INF_SCORE, INF_SCORE, 0, time()+600.0, ctx, cfg)
println("  $(ctx.nodes) nodes — warmup complete.\n")

# ── Profile ──────────────────────────────────────────────────────────────────

println("Profiling ($PROFILE_REPS repetitions, each depth $PROFILE_DEPTH)...")
Profile.clear()
@profile for _ in 1:PROFILE_REPS
    Cassandra.tt_clear!()
    ctx2 = SearchContext()
    _negamax(b, PROFILE_DEPTH, -INF_SCORE, INF_SCORE, 0, time()+600.0, ctx2, cfg)
end
println("Done.\n")

# ── Flat profile output ───────────────────────────────────────────────────────

buf = IOBuffer()
Profile.print(buf; format=:flat, sortedby=:count, mincount=5)
flat_str = String(take!(buf))

println("─── Flat profile (sorted by self count) ─────────────────────────────")
println(flat_str)

# ── Save to file ──────────────────────────────────────────────────────────────

sha = strip(read(`git -C $(dirname(abspath(@__FILE__))) rev-parse --short HEAD`, String))
outdir = joinpath(dirname(@__FILE__), "profiles")
mkpath(outdir)
outfile = joinpath(outdir, "$(sha)_d$(PROFILE_DEPTH).txt")

open(outfile, "w") do f
    println(f, "# Cassandra search profile — git $sha — depth $PROFILE_DEPTH — $(PROFILE_REPS)x")
    println(f, "# FEN: $(isempty(PROFILE_FEN) ? "startpos" : PROFILE_FEN)")
    println(f, "# Date: $(Dates.now())")
    println(f)
    write(f, flat_str)
end
println("Saved to: $outfile\n")

# ── Decision guide ────────────────────────────────────────────────────────────

println("""
─── How to read this for the make/unmake decision ───────────────────────────

Look for these functions in the flat profile above:

  Bobby.makeMove          — copy-make cost (board allocation + hash update)
  Bobby.updateSet         — ChessSet reconstruction per piece
  Bobby.getMoves / filterMoves — move generation cost (make/unmake won't help)
  Cassandra.classical_eval     — eval cost (make/unmake won't help)
  Cassandra._negamax / _qsearch — search overhead

Decision rule (rough):
  makeMove + updateSet ≥ 35% of total count  →  refactor worth it  (~1.5–2× NPS)
  makeMove + updateSet   20–35%              →  marginal; only if movegen also cut
  makeMove + updateSet < 20%                 →  skip; attack eval or movegen instead

GC time fraction (from search_bench.jl Alloc MB / GC% columns) is the other
signal: GC% > 15% in search ≡ memory pressure is real.
""")
