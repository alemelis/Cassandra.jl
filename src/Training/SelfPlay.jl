const MAX_GAME_MOVES = 500

# 1-ply policy-greedy move selection used during self-play.
function policy_best_move(model::CassandraModel, board::Bobby.Board)::Union{Bobby.Move,Nothing}
    legal = Bobby.getMoves(board, board.active)
    isempty(legal.moves) && return nothing
    _, logits = forward(model, board)
    scores = map(legal.moves) do m
        idx = get(UCI2IDX, Bobby.moveToUCI(m), 0)
        idx == 0 ? -Inf32 : logits[idx]
    end
    _, best = findmax(scores)
    return legal.moves[best]
end

function play_game(model_white::CassandraModel, model_black::CassandraModel;
                   max_moves::Int=MAX_GAME_MOVES)::Symbol
    game = Bobby.newGame()
    for _ in 1:max_moves
        Bobby.isDraw(game)      && return :draw
        Bobby.isCheckmate(game) && return game.history[end].active ? :black_wins : :white_wins
        Bobby.isStalemate(game) && return :draw

        board = Bobby.currentBoard(game)
        model = board.active ? model_white : model_black
        move  = policy_best_move(model, board)
        isnothing(move) && return board.active ? :black_wins : :white_wins
        Bobby.applyMove!(game, move)
    end
    return :draw
end

function evaluate(model_a::CassandraModel, model_b::CassandraModel, n_games::Int;
                  kwargs...)
    wins_a = 0; wins_b = 0; draws = 0

    for i in 1:n_games
        white, black = isodd(i) ? (model_a, model_b) : (model_b, model_a)
        result = play_game(white, black; kwargs...)
        a_is_white = isodd(i)
        if     result == :white_wins; a_is_white  ? (wins_a += 1) : (wins_b += 1)
        elseif result == :black_wins; !a_is_white ? (wins_a += 1) : (wins_b += 1)
        else   draws += 1
        end
    end

    score_a  = (wins_a + 0.5 * draws) / n_games
    elo_delta = score_a == 0.0 ? -Inf :
                score_a == 1.0 ?  Inf :
                -400 * log10(1 / score_a - 1)

    return (wins_a=wins_a, wins_b=wins_b, draws=draws,
            score_a=score_a, elo_delta=elo_delta)
end
