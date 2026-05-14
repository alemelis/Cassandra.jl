# Piece values for MVV-LVA capture ordering (Bobby piece type index 0..6)
const _CAPTURE_VALS = (0f0, 100f0, 320f0, 330f0, 500f0, 900f0, 20_000f0)

# Maximum ply for killer/history tables. Also the depth of pre-allocated
# per-ply scratch buffers in SearchContext.
const MAX_PLY = 128

# Worst-case legal move count from a single chess position is 218; round up
# to 256 for cache-friendly Vector sizes and to absorb null-move stub bumps.
const MAX_MOVES_PER_POS = 256

# Pre-allocated repetition stack capacity: game history + search tree.
const REP_STACK_CAPACITY = MAX_PLY + 512

# Sentinel "history disabled" matrix — allocated once, reused everywhere we
# need to call order_moves! without a real history table.
const EMPTY_HISTORY = zeros(Int32, 7, 64)

# ── Search context ────────────────────────────────────────────────────────────
# Reused across the entire iterative-deepening tree; reset before each search.
# Every per-node scratch buffer lives here so _negamax/_qsearch are
# allocation-free in the steady state.
mutable struct SearchContext
    nodes::Int
    # killers[ply] = (move_idx1, move_idx2) — indices into the moves array
    killers::Vector{NTuple{2,Int16}}
    # history[piece_type+1, to_sq+1] — bonus on β-cutoff
    history::Matrix{Int32}

    # Repetition: linear stack of position hashes along the current search
    # path. `rep_top` is the index of the most-recently-pushed hash.
    # Bounded scan up to `board.halfmove` entries detects in-tree repetitions
    # without hashing.
    rep_stack::Vector{UInt64}
    rep_top::Int

    # Per-ply scratch for move ordering. order_buf[ply+1] holds permutation
    # indices, score_buf[ply+1] the parallel scores. resize!'d in place; no
    # heap traffic after warm-up.
    order_buf::Vector{Vector{Int16}}
    score_buf::Vector{Vector{Float32}}

    function SearchContext()
        order_buf = Vector{Vector{Int16}}(undef, MAX_PLY + 2)
        score_buf = Vector{Vector{Float32}}(undef, MAX_PLY + 2)
        @inbounds for i in 1:(MAX_PLY + 2)
            order_buf[i] = Vector{Int16}(undef, MAX_MOVES_PER_POS)
            score_buf[i] = Vector{Float32}(undef, MAX_MOVES_PER_POS)
        end
        new(0,
            fill((Int16(0), Int16(0)), MAX_PLY),
            zeros(Int32, 7, 64),
            Vector{UInt64}(undef, REP_STACK_CAPACITY),
            0,
            order_buf,
            score_buf)
    end
end

function reset_ctx!(ctx::SearchContext)
    ctx.nodes = 0
    fill!(ctx.killers, (Int16(0), Int16(0)))
    fill!(ctx.history, Int32(0))
    ctx.rep_top = 0
    return ctx
end

# ── Repetition stack ─────────────────────────────────────────────────────────
# Path-only repetition (two-fold inside the tree counts as a draw, standard).

@inline function rep_push!(ctx::SearchContext, hash::UInt64)
    ctx.rep_top += 1
    @inbounds ctx.rep_stack[ctx.rep_top] = hash
    return ctx
end

@inline function rep_pop!(ctx::SearchContext)
    ctx.rep_top -= 1
    return ctx
end

# Scan backwards up to `halfmove` entries (positions since the last
# irreversible move) for a matching hash. Hashes encode side-to-move, so a
# match implies same side. We step by 2 because only same-side positions
# can repeat — saves half the comparisons.
@inline function is_repetition(ctx::SearchContext, hash::UInt64, halfmove::Int)::Bool
    scan = min(ctx.rep_top, halfmove)
    scan <= 0 && return false
    top = ctx.rep_top
    @inbounds for i in 2:2:scan
        if ctx.rep_stack[top - i + 1] == hash
            return true
        end
    end
    return false
end

# ── Move priority ─────────────────────────────────────────────────────────────
@inline function _move_priority(m::Bobby.Move,
                                tt_best::Int16, i::Int16,
                                killers::NTuple{2,Int16},
                                history::Matrix{Int32})::Float32
    # 1. TT best move
    i == tt_best && return 2_000_000f0

    # 2. Captures: MVV-LVA
    vt = Int(m.take.type)
    if vt != 0
        victim   = _CAPTURE_VALS[vt + 1]
        attacker = _CAPTURE_VALS[Int(m.type) + 1]
        return 1_000_000f0 + victim * 10f0 - attacker
    end

    s = 0f0
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

    return s
end

# In-place move ordering. Caller passes pre-allocated `order` and `scores`
# buffers (from SearchContext.order_buf / score_buf) — no allocations here.
function order_moves!(order::Vector{Int16}, scores::Vector{Float32},
                      moves::Vector{Bobby.Move},
                      tt_best::Int16,
                      killers::NTuple{2,Int16},
                      history::Matrix{Int32})
    n = length(moves)
    resize!(order, n)
    resize!(scores, n)
    @inbounds for i in 1:n
        order[i] = Int16(i)
        scores[i] = _move_priority(moves[i], tt_best, Int16(i), killers, history)
    end
    # Insertion sort on the order permutation, comparing by the parallel
    # scores array. Insertion sort is allocation-free (sort!(...; by=closure)
    # on Julia 1.12 boxes the closure), and the typical post-move-ordering
    # list is near-sorted, so this is fast in practice.
    @inbounds for i in 2:n
        oi = order[i]
        si = scores[oi]
        j  = i
        while j > 1
            oprev = order[j - 1]
            scores[oprev] >= si && break
            order[j] = oprev
            j -= 1
        end
        order[j] = oi
    end
    return order
end

# Update killer and history on a β-cutoff from a quiet move
function update_ordering!(ctx::SearchContext, move::Bobby.Move, idx::Int16,
                          ply::Int, depth::Int)
    move.take.type != 0 && return  # quiets only

    k1, _ = ctx.killers[ply + 1]
    idx != k1 && (ctx.killers[ply + 1] = (idx, k1))

    to_sq = Int(trailing_zeros(move.to)) + 1
    pt    = Int(move.type) + 1
    if 1 <= pt <= 7 && 1 <= to_sq <= 64
        ctx.history[pt, to_sq] = min(ctx.history[pt, to_sq] + Int32(depth * depth),
                                     Int32(1_000_000))
    end
end
