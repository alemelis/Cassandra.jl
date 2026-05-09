module Book

using Bobby, JSON3, Random

import ..START_FEN

const BOOK_PATH    = Ref{String}(
    get(ENV, "CASSANDRA_BOOK", joinpath(@__DIR__, "..", "book", "book.json")))
const CURATED_PATH = joinpath(@__DIR__, "..", "book", "curated.json")

# board.hash (UInt64) → Vector of (move, weight, label) NamedTuples
const ENTRIES = Ref{Dict{UInt64,Vector}}(Dict{UInt64,Vector}())
const MTIME   = Ref{Float64}(0.0)
const LOCK    = ReentrantLock()

# ── Persistence ───────────────────────────────────────────────────────────────

function load!(path::AbstractString = BOOK_PATH[])
    lock(LOCK) do
        if !isfile(path)
            ENTRIES[] = Dict{UInt64,Vector}(); MTIME[] = 0.0; return
        end
        m = mtime(path)
        m == MTIME[] && return
        raw = JSON3.read(read(path, String))
        d = Dict{UInt64,Vector}()
        for (k, v) in raw.entries
            h = parse(UInt64, String(k))
            d[h] = [(move   = String(e.move),
                     weight = Int(get(e, :weight, 1)),
                     label  = String(get(e, :label, ""))) for e in v]
        end
        ENTRIES[] = d
        MTIME[]   = m
    end
end

function maybe_reload!()
    isfile(BOOK_PATH[]) || return
    mtime(BOOK_PATH[]) != MTIME[] && load!()
end

function save!(path::AbstractString = BOOK_PATH[])
    lock(LOCK) do
        mkpath(dirname(path))
        serialized = Dict(
            string(k) => [Dict("move" => e.move, "weight" => e.weight, "label" => e.label)
                          for e in v]
            for (k, v) in ENTRIES[]
        )
        open(path, "w") do io
            JSON3.write(io, Dict("version" => 1, "entries" => serialized))
        end
        MTIME[] = mtime(path)
    end
end

# ── Query ─────────────────────────────────────────────────────────────────────

enabled() = !isempty(ENTRIES[])

function probe(board::Bobby.Board;
               rng::AbstractRNG = Random.GLOBAL_RNG)::Union{String,Nothing}
    maybe_reload!()
    moves = get(ENTRIES[], board.hash, nothing)
    isnothing(moves) && return nothing
    isempty(moves) && return nothing
    total = sum(e.weight for e in moves; init=0)
    total <= 0 && return moves[1].move
    r = rand(rng) * total
    acc = 0
    for e in moves
        acc += e.weight
        r <= acc && return e.move
    end
    return moves[end].move
end

function list_entries()
    lock(LOCK) do
        [(hash = string(k), moves = v) for (k, v) in ENTRIES[]]
    end
end

# ── Mutation ──────────────────────────────────────────────────────────────────

function _upsert!(h::UInt64, uci::String, label::String)
    moves = get!(ENTRIES[], h, [])
    if findfirst(e -> e.move == uci, moves) === nothing
        push!(moves, (move=uci, weight=1, label=label))
    end
end

function add_line!(name::AbstractString, uci_moves::AbstractString)
    lock(LOCK) do
        board = Bobby.loadFen(START_FEN)
        for uci in split(strip(uci_moves))
            m = Bobby.uciMoveToMove(board, String(uci))
            _upsert!(board.hash, String(uci), String(name))
            board = Bobby.makeMove(board, m)
        end
    end
end

function delete_entry!(hash_str::AbstractString, uci::AbstractString)
    lock(LOCK) do
        h = parse(UInt64, hash_str)
        moves = get(ENTRIES[], h, nothing)
        isnothing(moves) && return
        filter!(e -> e.move != uci, moves)
        isempty(moves) && delete!(ENTRIES[], h)
    end
end

function import_curated!(path::AbstractString = CURATED_PATH)
    isfile(path) || return
    raw = JSON3.read(read(path, String))
    for line in get(raw, :lines, JSON3.Array[])
        add_line!(String(line.name), String(line.moves))
    end
end

function clear!()
    lock(LOCK) do
        ENTRIES[] = Dict{UInt64,Vector}()
        MTIME[] = 0.0
    end
end

end # module Book
