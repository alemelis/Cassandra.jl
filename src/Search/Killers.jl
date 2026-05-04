const KILLER_PLY_MAX = 64

const _KILLERS = [UInt64(0) for _ in 1:KILLER_PLY_MAX*2]

const _HISTORY = zeros(Int32, 64, 64)

 killers_clear!() = fill!(_KILLERS, UInt64(0))
history_clear!() = fill!(_HISTORY, 0)

@inline _move_key(m::Bobby.Move)::UInt64 =
    (UInt64(_sq2idx(m.from)) << 6) | UInt64(_sq2idx(m.to))

function killer_record!(ply::Int, m::Bobby.Move)
    ply > KILLER_PLY_MAX && return
    key = _move_key(m)
    k1 = _KILLERS[ply * 2 - 1]
    k2 = _KILLERS[ply * 2]
    k1 == key && return
    _KILLERS[ply * 2] = k1
    _KILLERS[ply * 2 - 1] = key
end

function history_bump!(m::Bobby.Move, depth::Int)
    i = _sq2idx(m.from) + 1
    j = _sq2idx(m.to) + 1
    _HISTORY[i, j] += Int32(depth * depth)
end

@inline function killer_score(ply::Int, m::Bobby.Move)::Float32
    ply > KILLER_PLY_MAX && return 0f0
    key = _move_key(m)
    _KILLERS[ply * 2 - 1] == key && return 9000f0
    _KILLERS[ply * 2] == key && return 8000f0
    return 0f0
end

@inline history_score(m::Bobby.Move)::Float32 =
    Float32(_HISTORY[_sq2idx(m.from) + 1, _sq2idx(m.to) + 1])