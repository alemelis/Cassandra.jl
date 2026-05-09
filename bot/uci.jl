using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Bobby
using Cassandra

const SETUPS_DIR = get(ENV, "SETUPS_DIR", joinpath(@__DIR__, "..", "setups"))

function _load_setup()
    path = joinpath(SETUPS_DIR, "deployed.json")
    cfg = load_engine_cfg(path)
    apply_engine_cfg!(cfg)
    @info "[uci] Setup: $(cfg.name)  depth=$(cfg.search.max_depth)  qsearch=$(cfg.search.qsearch)"
    cfg
end

# Parse "position startpos moves …" or "position fen <fen> moves …"
function parse_position(tokens::Vector{<:AbstractString})::Bobby.Board
    i = 1
    if tokens[i] == "startpos"
        board = Bobby.loadFen(START_FEN); i += 1
    elseif tokens[i] == "fen"
        fen_parts = String[]; i += 1
        while i <= length(tokens) && tokens[i] != "moves"
            push!(fen_parts, tokens[i]); i += 1
        end
        board = Bobby.loadFen(join(fen_parts, " "))
    else
        board = Bobby.loadFen(START_FEN)
    end
    if i <= length(tokens) && tokens[i] == "moves"
        for uci in tokens[i+1:end]
            m = Bobby.uciMoveToMove(board, String(uci))
            board = Bobby.makeMove(board, m)
        end
    end
    return board
end

# Derive time limit from go parameters; returns nothing to use setup default.
function time_limit_from_go(tokens::Vector{<:AbstractString}, active::Bool)::Union{Float64,Nothing}
    d = Dict{String,Int}()
    i = 1
    while i < length(tokens)
        if tokens[i] in ("wtime","btime","winc","binc","movestogo","movetime","depth")
            d[tokens[i]] = parse(Int, tokens[i+1]); i += 2
        else
            i += 1
        end
    end
    haskey(d, "movetime") && return d["movetime"] / 1000.0
    if haskey(d, "depth")
        set_max_depth!(d["depth"]); return nothing
    end
    key, inc_key = active ? ("wtime", "winc") : ("btime", "binc")
    time_ms = get(d, key, 0)
    time_ms == 0 && return nothing
    inc_ms    = get(d, inc_key, 0)
    movestogo = get(d, "movestogo", 30)
    alloc_ms  = time_ms / movestogo + inc_ms * 0.8
    return clamp(alloc_ms / 1000.0, 0.05, 10.0)
end

function _warmup(cfg::EngineConfig)
    saved_t, saved_d = cfg.search.time_limit_s, cfg.search.max_depth
    cfg.search.time_limit_s, cfg.search.max_depth = 0.5, 4
    try
        select_move(Bobby.loadFen(START_FEN))
    catch e
        @warn "[uci] warmup failed" exception=e
    finally
        cfg.search.time_limit_s, cfg.search.max_depth = saved_t, saved_d
    end
end

function run()
    cfg    = _load_setup()
    board  = Bobby.loadFen(START_FEN)
    warmed = false

    while !eof(stdin)
        line = readline(stdin)
        isempty(line) && continue
        tokens = split(line)
        cmd = tokens[1]

        if cmd == "uci"
            println("id name Cassandra.jl")
            println("id author alemelis")
            println("uciok")

        elseif cmd == "isready"
            warmed || (_warmup(cfg); warmed = true)
            println("readyok")

        elseif cmd == "ucinewgame"
            tt_clear!()
            board = Bobby.loadFen(START_FEN)

        elseif cmd == "position"
            board = parse_position(tokens[2:end])

        elseif cmd == "go"
            tl = time_limit_from_go(tokens[2:end], board.active)
            tl !== nothing && (get_engine_cfg().search.time_limit_s = tl)
            move = select_move(board)
            println("bestmove ", move === nothing ? "0000" : move)

        elseif cmd == "quit"
            break
        end

        flush(stdout)
    end
end

run()
