# Piece values by Bobby type index (0=NONE, 1=P, 2=N, 3=B, 4=R, 5=Q, 6=K)
const _CAPTURE_VALS = (0f0, 100f0, 320f0, 330f0, 500f0, 900f0, 20_000f0)

function _move_priority(m::Bobby.Move, logits::Vector{Float32}, tt_best::Int16, i::Int16)::Float32
    s = 0f0
    i == tt_best && (s += 100_000f0)
    vt = Int(m.take.type)
    if vt != 0
        s += 10_000f0 + _CAPTURE_VALS[vt + 1] * 10f0 - _CAPTURE_VALS[Int(m.type) + 1]
    end
    idx = get(UCI2IDX, Bobby.moveToUCI(m), 0)
    idx > 0 && (s += logits[idx])
    return s
end

function order_moves!(order::Vector{Int16}, moves::Vector{Bobby.Move},
                      logits::Vector{Float32}, tt_best::Int16)
    n = length(moves)
    resize!(order, n)
    scores = Vector{Float32}(undef, n)
    for i in 1:n
        order[i] = Int16(i)
        scores[i] = _move_priority(moves[i], logits, tt_best, Int16(i))
    end
    sort!(order, by=i -> -scores[i])
    return order
end
