const TT_SIZE  = 1 << 20   # 1M entries
const TT_EXACT = UInt8(0)
const TT_LOWER = UInt8(1)  # failed high (score >= beta)
const TT_UPPER = UInt8(2)  # failed low  (score <= alpha)

const INF_SCORE  = 200_000f0
const MATE_SCORE = 100_000f0

mutable struct TTEntry
    hash::UInt64
    depth::Int8
    score::Float32
    flag::UInt8
    best_idx::Int16
end

const _TT = [TTEntry(UInt64(0), Int8(0), 0f0, TT_EXACT, Int16(0)) for _ in 1:TT_SIZE]

@inline _tt_slot(h::UInt64) = Int(h % TT_SIZE) + 1

function tt_probe(hash::UInt64, depth::Int, alpha::Float32, beta::Float32)
    e = _TT[_tt_slot(hash)]
    e.hash != hash && return nothing, Int16(0)
    hint = e.best_idx
    e.depth < depth && return nothing, hint
    if e.flag == TT_EXACT
        return e.score, hint
    elseif e.flag == TT_LOWER && e.score >= beta
        return e.score, hint
    elseif e.flag == TT_UPPER && e.score <= alpha
        return e.score, hint
    end
    return nothing, hint
end

function tt_store!(hash::UInt64, depth::Int, score::Float32, flag::UInt8, best_idx::Int16)
    slot = _tt_slot(hash)
    e = _TT[slot]
    e.hash == hash && e.depth > depth && return   # keep deeper result
    _TT[slot] = TTEntry(hash, Int8(clamp(depth, -128, 127)), score, flag, best_idx)
end
