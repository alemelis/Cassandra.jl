# Piece values for MVV-LVA capture ordering (Bobby piece type index 0..6)
const _CAPTURE_VALS = (0f0, 100f0, 320f0, 330f0, 500f0, 900f0, 20_000f0)

# Maximum ply for killer/history tables
const MAX_PLY = 128

# ── Search context ────────────────────────────────────────────────────────────
# Reused across the entire iterative-deepening tree; reset before each search.
mutable struct SearchContext
    nodes::Int
    # killers[ply] = (move_idx1, move_idx2) — indices into the moves array
    killers::Vector{NTuple{2,Int16}}
    # history[piece_type+1, to_sq+1] — bonus on β-cutoff
    history::Matrix{Int32}

    function SearchContext()
        new(0,
            fill((Int16(0), Int16(0)), MAX_PLY),
            zeros(Int32, 7, 64))
    end
end

function reset_ctx!(ctx::SearchContext)
    ctx.nodes = 0
    fill!(ctx.killers, (Int16(0), Int16(0)))
    fill!(ctx.history, Int32(0))
end

# ── Move priority ─────────────────────────────────────────────────────────────
@inline function _move_priority(m::Bobby.Move, logits::Union{Vector{Float32},Nothing},
                                tt_best::Int16, i::Int16,
                                killers::NTuple{2,Int16},
                                history::Matrix{Int32})::Float32
    s = 0f0

    # 1. TT best move
    i == tt_best && return 2_000_000f0

    # 2. Captures: MVV-LVA
    vt = Int(m.take.type)
    if vt != 0
        victim   = _CAPTURE_VALS[vt + 1]
        attacker = _CAPTURE_VALS[Int(m.type) + 1]
        s += 1_000_000f0 + victim * 10f0 - attacker
        return s
    end

    # 3. Promotions (non-capture)
    m.promotion != 0 && (s += 900_000f0)

    # 4. Killers
    (i == killers[1] || i == killers[2]) && (s += 800_000f0)

    # 5. History
    to_sq = Int(trailing_zeros(m.to)) + 1
    pt    = Int(m.type) + 1
    if 1 <= pt <= 7 && 1 <= to_sq <= 64
        s += Float32(history[pt, to_sq])
    end

    # 6. NN policy logits (optional)
    if logits !== nothing
        idx = get(UCI2IDX, Bobby.moveToUCI(m), 0)
        idx > 0 && (s += logits[idx])
    end

    return s
end

function order_moves!(order::Vector{Int16}, moves::Vector{Bobby.Move},
                      logits::Union{Vector{Float32},Nothing},
                      tt_best::Int16,
                      killers::NTuple{2,Int16},
                      history::Matrix{Int32})
    n = length(moves)
    resize!(order, n)
    scores = Vector{Float32}(undef, n)
    for i in 1:n
        order[i] = Int16(i)
        scores[i] = _move_priority(moves[i], logits, tt_best, Int16(i), killers, history)
    end
    sort!(order, by=i -> -scores[i])
    return order
end

# Update killer and history on a β-cutoff from a quiet move
function update_ordering!(ctx::SearchContext, move::Bobby.Move, idx::Int16,
                          ply::Int, depth::Int)
    # Only quiet moves
    move.take.type != 0 && return

    # Killers: shift in new killer if not already present
    k1, k2 = ctx.killers[ply + 1]
    if idx != k1
        ctx.killers[ply + 1] = (idx, k1)
    end

    # History: increment by depth² (clamped to avoid overflow)
    to_sq = Int(trailing_zeros(move.to)) + 1
    pt    = Int(move.type) + 1
    if 1 <= pt <= 7 && 1 <= to_sq <= 64
        ctx.history[pt, to_sq] = min(ctx.history[pt, to_sq] + Int32(depth * depth), Int32(1_000_000))
    end
end
