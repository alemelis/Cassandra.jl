#!/usr/bin/env julia
#
# Single-position search profiler.
#
# Inputs (env vars):
#   FEN           position to search    (default: start position)
#   POS_LABEL     display label         (default: "startpos")
#   SECONDS       wall-time budget      (default: 5.0)
#   SETUPS_DIR    deployed setup dir    (default: /data/setups)
#   LOGS_DIR      output dir            (default: /data/logs)
#
# Outputs (under $LOGS_DIR/profile/):
#   <ts>.collapsed   Brendan-Gregg-style stacks: "root;a;b;leaf <count>"
#   <ts>.meta.json   {ts, fen, position_label, seconds, total_samples,
#                     truncated, setup_name, setup_hash, partial, error}
#
# Notes:
#   - Pre-warms with one full search() before sampling so JIT compilation
#     doesn't pollute the flame.
#   - Walks the full inline chain in lidict[ip] so inlined Bobby/Cassandra
#     functions are recovered; without this, inlining destroys the flame.
#   - Uses an atexit hook to flush a partial profile if the container
#     receives SIGTERM mid-run.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Bobby
using Cassandra
using Profile
using JSON3
using Dates

const SETUPS_DIR = get(ENV, "SETUPS_DIR", "/data/setups")
const LOGS_DIR   = get(ENV, "LOGS_DIR",   "/data/logs")
const FEN        = let f = get(ENV, "FEN", ""); isempty(f) ? Cassandra.START_FEN : f end
const POS_LABEL  = get(ENV, "POS_LABEL", "startpos")
const SECONDS    = parse(Float64, get(ENV, "SECONDS", "5.0"))

const PROFILE_DIR = joinpath(LOGS_DIR, "profile")
mkpath(PROFILE_DIR)

const TS       = Dates.format(now(Dates.UTC), "yyyymmddTHHMMSS")
const OUT_DATA = joinpath(PROFILE_DIR, "$TS.collapsed")
const OUT_META = joinpath(PROFILE_DIR, "$TS.meta.json")

# ── Symbolication helpers ────────────────────────────────────────────────────

# Drop noisy module prefixes; keep Base/Core so stdlib is visually distinct.
function _short_func(sf::Base.StackTraces.StackFrame)::String
    name = string(sf.func)
    for prefix in ("Cassandra.", "Bobby.", "Main.")
        startswith(name, prefix) && (name = name[length(prefix)+1:end]; break)
    end
    name == "" ? "?" : name
end

function _frame_key(sf::Base.StackTraces.StackFrame)::String
    fname = _short_func(sf)
    file  = sf.file === nothing ? "" : basename(string(sf.file))
    suffix = sf.from_c ? " [C]" : ""
    line   = sf.line > 0 ? ":$(sf.line)" : ""
    isempty(file) ? "$fname$suffix" : "$fname @ $file$line$suffix"
end

# True for a frame name we treat as the flame root.
# Trimming above this drops 50+ Julia/libc startup frames per sample so the
# flame opens at Cassandra.search instead of at __libc_start_main.
_is_root(s::AbstractString) = startswith(s, "search @ AlphaBeta.jl")

# Walk Profile.retrieve() data into a Dict{stack_string => count}.
# Stacks not containing `search` are dropped (Profile listener task, etc.).
function _collapsed(data::Vector{UInt}, lidict)::Dict{String,Int}
    counts = Dict{String,Int}()
    frames = String[]                           # one stack, leaf → outer
    function flush!()
        if !isempty(frames)
            # frames is leaf→outer; root is the last index that matches search.
            root_idx = findlast(_is_root, frames)
            if root_idx !== nothing
                # Keep [1..root_idx] (leaf to search) and reverse to root-leftmost.
                trimmed = view(frames, 1:root_idx)
                key = join(Iterators.reverse(trimmed), ";")
                counts[key] = get(counts, key, 0) + 1
            end
            empty!(frames)
        end
    end
    i = 1
    while i <= length(data)
        ip = data[i]
        if ip == 0
            flush!()
            i += 1
            continue
        end
        sfs = get(lidict, ip, nothing)
        if sfs !== nothing
            for sf in sfs
                push!(frames, _frame_key(sf))
            end
        end
        i += 1
    end
    flush!()                # tail without terminator
    return counts
end

function _write_collapsed(counts::Dict{String,Int})
    open(OUT_DATA, "w") do io
        for (k, n) in counts
            println(io, "$k $n")
        end
    end
end

# ── Setup ────────────────────────────────────────────────────────────────────

function _load_setup()
    path = joinpath(SETUPS_DIR, "deployed.json")
    if isfile(path)
        cfg = Cassandra.load_engine_cfg(path)
        Cassandra.apply_engine_cfg!(cfg)
    end
    cfg = Cassandra.get_engine_cfg()
    (name = cfg.name, hash = Cassandra.cfg_hash(cfg), cfg = cfg)
end

# ── Result writers (called from main + atexit) ───────────────────────────────

const RESULT = Ref{Dict{String,Any}}(Dict{String,Any}(
    "ts"             => TS,
    "fen"            => FEN,
    "position_label" => POS_LABEL,
    "seconds"        => SECONDS,
    "total_samples"  => 0,
    "truncated"      => false,
    "setup_name"     => "",
    "setup_hash"     => "",
    "partial"        => false,
    "error"          => nothing,
))
const FLUSHED = Ref(false)

function _write_meta()
    FLUSHED[] && return
    open(OUT_META, "w") do io
        JSON3.write(io, RESULT[])
    end
    FLUSHED[] = true
end

# If the container is killed (SIGTERM from `docker stop`), flush whatever
# samples Profile already collected and tag the meta as partial.
atexit() do
    if !FLUSHED[]
        try
            data, lidict = Profile.retrieve()
            counts = _collapsed(data, lidict)
            _write_collapsed(counts)
            RESULT[]["total_samples"] = sum(values(counts); init=0)
            RESULT[]["partial"]       = true
            _write_meta()
        catch
            # last-ditch — write meta with no data
            try _write_meta() catch end
        end
    end
end

# ── Main ─────────────────────────────────────────────────────────────────────

function main()
    setup = _load_setup()
    RESULT[]["setup_name"] = setup.name
    RESULT[]["setup_hash"] = setup.hash

    println("Profile run $TS")
    println("  position: $POS_LABEL  ($FEN)")
    println("  seconds:  $SECONDS")
    println("  setup:    $(setup.name)  ($(setup.hash))")
    flush(stdout)

    board = Bobby.loadFen(FEN)

    # 1) Pre-warm: compile the search hot path before sampling. Mirror the
    #    pattern in benchmark/search_bench.jl (one call per position).
    print("Warming up… "); flush(stdout)
    setup.cfg.search.time_limit_s = 0.5
    Cassandra.tt_clear!()
    Cassandra.search(board)
    println("done."); flush(stdout)

    # 2) Configure for the real run. Lift max_depth so wall-time SECONDS is
    #    the binding constraint (deployed setups may cap depth low for
    #    Lichess time controls; for profiling we want the full budget).
    setup.cfg.search.time_limit_s = SECONDS
    setup.cfg.search.max_depth    = 64
    setup.cfg.book.enabled        = false   # don't short-circuit on book hit
    Cassandra.tt_clear!()
    Profile.clear()
    # 1 kHz; 10M-slot buffer (~80 MB) holds ≥ several minutes of samples.
    BUF_SIZE = 10_000_000
    Profile.init(n = BUF_SIZE, delay = 0.001)

    # 3) Sample.
    println("Sampling for $(SECONDS)s…"); flush(stdout)
    t0 = time()
    try
        Profile.@profile Cassandra.search(board)
    catch e
        RESULT[]["error"] = string(e)
        @warn "search failed during profile" exception=(e, catch_backtrace())
    end
    elapsed = time() - t0

    # 4) Symbolicate + write.
    data, lidict = Profile.retrieve()
    truncated = length(data) >= BUF_SIZE              # buffer cap hit
    counts    = _collapsed(data, lidict)
    total     = sum(values(counts); init = 0)

    _write_collapsed(counts)
    RESULT[]["total_samples"] = total
    RESULT[]["truncated"]     = truncated
    _write_meta()

    elapsed_s = round(elapsed; digits = 1)
    suffix    = truncated ? " (TRUNCATED — buffer full)" : ""
    println("Done in $(elapsed_s)s · $total samples · $(length(counts)) unique stacks$suffix")
    println("  → $OUT_DATA")
    println("  → $OUT_META")
end

main()
