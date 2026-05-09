const TT_SIZE  = 1 << 20   # 1M entries; resized via EngineConfig at startup
const TT_EXACT = UInt8(0)
const TT_LOWER = UInt8(1)  # failed high (score >= beta)
const TT_UPPER = UInt8(2)  # failed low  (score <= alpha)

const INF_SCORE  = 200_000f0
const MATE_SCORE = 100_000f0
const MATE_BOUND = MATE_SCORE - 500f0   # scores above this are mate scores

mutable struct TTEntry
    hash::UInt64
    depth::Int8
    score::Float32
    flag::UInt8
    best_idx::Int16
end

const _TT = [TTEntry(UInt64(0), Int8(0), 0f0, TT_EXACT, Int16(0)) for _ in 1:TT_SIZE]

@inline _tt_slot(h::UInt64) = Int(h % TT_SIZE) + 1

# Mate scores are stored relative to the position (not the root) so they can
# be reused from transpositions at different distances from the root.
@inline _score_to_tt(score::Float32, ply::Int)::Float32 =
    score > MATE_BOUND  ? score + Float32(ply) :
    score < -MATE_BOUND ? score - Float32(ply) : score

@inline _score_from_tt(score::Float32, ply::Int)::Float32 =
    score > MATE_BOUND  ? score - Float32(ply) :
    score < -MATE_BOUND ? score + Float32(ply) : score

function tt_probe(hash::UInt64, depth::Int, ply::Int, alpha::Float32, beta::Float32)
    e = _TT[_tt_slot(hash)]
    e.hash != hash && return nothing, Int16(0)
    hint = e.best_idx
    e.depth < depth && return nothing, hint
    score = _score_from_tt(e.score, ply)
    if e.flag == TT_EXACT
        return score, hint
    elseif e.flag == TT_LOWER && score >= beta
        return score, hint
    elseif e.flag == TT_UPPER && score <= alpha
        return score, hint
    end
    return nothing, hint
end

function tt_store!(hash::UInt64, depth::Int, ply::Int,
                   score::Float32, flag::UInt8, best_idx::Int16)
    slot = _tt_slot(hash)
    e = _TT[slot]
    e.hash == hash && e.depth > depth && return   # keep deeper result
    _TT[slot] = TTEntry(hash, Int8(clamp(depth, -128, 127)),
                        _score_to_tt(score, ply), flag, best_idx)
end

tt_clear!() = fill!(_TT, TTEntry(UInt64(0), Int8(0), 0f0, TT_EXACT, Int16(0)))
