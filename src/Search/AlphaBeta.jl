const AB_TIME_LIMIT = 3.0   # seconds per move

# Runtime-tunable iterative-deepening cap. Mutated via Cassandra.set_max_depth!,
# which the bot exposes through its control server.
const MAX_DEPTH = Ref(parse(Int, get(ENV, "BOT_MAX_DEPTH", "3")))

set_max_depth!(d::Integer) = (MAX_DEPTH[] = clamp(Int(d), 1, 64))
get_max_depth() = MAX_DEPTH[]

# Sentinel returned by _negamax when the deadline trips. Callers check
# `time() > deadline` and discard polluted scores instead of storing them.
const ABORT_SCORE = 0f0

function _negamax(model::CassandraModel, board::Bobby.Board, depth::Int,
                  alpha::Float32, beta::Float32,
                  buf::Array{Float32,3}, order::Vector{Int16},
                  deadline::Float64, seen::Set{UInt64})::Float32

    time() > deadline && return ABORT_SCORE

    board.hash in seen && return 0f0   # repetition on search path → draw

    tt_score, tt_best = tt_probe(board.hash, depth, alpha, beta)
    tt_score !== nothing && return tt_score

    legal = Bobby.getMoves(board, board.active)

    if isempty(legal.moves)
        return Bobby.inCheck(board, board.active) ? -MATE_SCORE : 0f0
    end
    board.halfmove >= 100 && return 0f0   # fifty-move rule

    if depth <= 0
        return value_eval(model, board, buf)
    end

    _, logits = forward(model, board, buf)
    order_moves!(order, legal.moves, logits, tt_best)

    push!(seen, board.hash)

    orig_alpha = alpha
    best_score = -INF_SCORE
    best_idx   = order[1]
    aborted    = false

    for i in order
        child = Bobby.makeMove(board, legal.moves[i])
        child_score = -_negamax(model, child, depth - 1, -beta, -alpha,
                                buf, Vector{Int16}(), deadline, seen)
        # If the deadline tripped during the child search, child_score is
        # garbage (sentinel). Bail without trusting it or storing TT.
        if time() > deadline
            aborted = true
            break
        end
        if child_score > best_score
            best_score = child_score
            best_idx   = i
        end
        alpha = max(alpha, best_score)
        alpha >= beta && break
    end

    delete!(seen, board.hash)

    aborted && return ABORT_SCORE

    flag = best_score <= orig_alpha ? TT_UPPER :
           best_score >= beta       ? TT_LOWER : TT_EXACT
    tt_store!(board.hash, depth, best_score, flag, best_idx)

    return best_score
end

function search(model::CassandraModel, board::Bobby.Board;
                time_limit::Float64=AB_TIME_LIMIT)::Union{String,Nothing}
    legal = Bobby.getMoves(board, board.active)
    isempty(legal.moves) && return nothing

    buf      = Array{Float32,3}(undef, 8, 8, Bobby.N_PLANES)
    order    = Vector{Int16}()
    seen     = Set{UInt64}()
    deadline = time() + time_limit

    _, logits = forward(model, board, buf)
    order_moves!(order, legal.moves, logits, Int16(0))

    best_move = legal.moves[order[1]]
    max_depth = MAX_DEPTH[]

    for depth in 1:max_depth
        time() > deadline && break

        iter_best_score = -INF_SCORE
        iter_best_idx   = order[1]
        alpha = -INF_SCORE
        beta  =  INF_SCORE

        move_scores = Dict{Int16,Float32}()

        for i in order
            child = Bobby.makeMove(board, legal.moves[i])
            score = -_negamax(model, child, depth - 1, -beta, -alpha,
                              buf, Vector{Int16}(), deadline, seen)
            time() > deadline && break
            move_scores[i] = score
            if score > iter_best_score
                iter_best_score = score
                iter_best_idx   = i
            end
            alpha = max(alpha, score)
        end

        time() > deadline && break

        if iter_best_score <= 0f0
            winning = Int16[]
            drawing = Int16[]
            for (i, score) in move_scores
                if score > 0f0
                    push!(winning, i)
                elseif score == 0f0
                    push!(drawing, i)
                end
            end
            if !isempty(winning)
                iter_best_idx = winning[1]
                iter_best_score = 1f0
            elseif !isempty(drawing)
                iter_best_idx = drawing[1]
                iter_best_score = 0f0
            end
        end

        best_move = legal.moves[iter_best_idx]
        filter!(x -> x != iter_best_idx, order)
        pushfirst!(order, iter_best_idx)
    end

    return Bobby.moveToUCI(best_move)
end

# Bot entry point: alpha-beta search with material eval at leaves.
# Swap material_eval → value_eval once the value head is trained.
function select_move(model::CassandraModel, board::Bobby.Board)::Union{String,Nothing}
    return search(model, board)
end