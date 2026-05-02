function value_eval(model::CassandraModel, board::Bobby.Board,
                    buf::Array{Float32,3}=_fresh_buf())::Float32
    v, _ = forward(model, board, buf)
    return v
end

function policy_info(model::CassandraModel, board::Bobby.Board,
                     buf::Array{Float32,3}=_fresh_buf())
    value, logits = forward(model, board, buf)
    legal = Bobby.getMoves(board, board.active)

    legal_uci   = String[]
    legal_logit = Float32[]
    for m in legal.moves
        uci = Bobby.moveToUCI(m)
        idx = get(UCI2IDX, uci, 0)
        idx == 0 && continue
        push!(legal_uci, uci)
        push!(legal_logit, logits[idx])
    end

    if isempty(legal_uci)
        return Float32(value), 0f0, NamedTuple[]
    end

    lmax  = maximum(legal_logit)
    e     = exp.(legal_logit .- lmax)
    probs = e ./ sum(e)
    ent   = -sum(p * log(p + 1f-9) for p in probs)

    order = sortperm(probs, rev=true)
    n_top = min(5, length(order))
    top5  = [(move=legal_uci[i], prob=round(Float64(probs[i]); digits=4)) for i in order[1:n_top]]

    return Float32(value), Float32(ent), top5
end
