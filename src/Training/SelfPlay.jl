const MAX_GAME_MOVES = 500

function select_move(model::CassandraModel, board::Bobby.Board)::Union{String,Nothing}
    m = _model_select_move(model, board)
    isnothing(m) && return nothing
    return Bobby.moveToUCI(m)
end

function _model_select_move(model::CassandraModel, board::Bobby.Board)::Union{Bobby.Move,Nothing}
    legal = Bobby.getMoves(board, board.active)
    isempty(legal.moves) && return nothing

    _, logits = forward(model, board)

    # score each legal move by its policy logit
    scores = map(legal.moves) do m
        idx = get(UCI2IDX, Bobby.moveToUCI(m), 0)
        idx == 0 ? -Inf32 : logits[idx]
    end

    # softmax sample
    scores = Float32.(scores)
    scores .-= maximum(scores)
    probs = exp.(scores)
    probs ./= sum(probs)

    r = rand(Float32)
    cumsum = 0f0
    for (i, p) in enumerate(probs)
        cumsum += p
        cumsum >= r && return legal.moves[i]
    end
    return legal.moves[end]
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
        move  = _model_select_move(model, board)
        isnothing(move) && return board.active ? :black_wins : :white_wins
        Bobby.applyMove!(game, move)
    end
    return :draw  # adjudicate long games as draws
end

function evaluate(model_a::CassandraModel, model_b::CassandraModel, n_games::Int;
                  kwargs...)
    wins_a = 0; wins_b = 0; draws = 0

    for i in 1:n_games
        # alternate colours
        if isodd(i)
            result = play_game(model_a, model_b; kwargs...)
            if result == :white_wins;     wins_a += 1
            elseif result == :black_wins; wins_b += 1
            else                          draws  += 1; end
        else
            result = play_game(model_b, model_a; kwargs...)
            if result == :white_wins;     wins_b += 1
            elseif result == :black_wins; wins_a += 1
            else                          draws  += 1; end
        end
    end

    score_a = (wins_a + 0.5 * draws) / n_games
    elo_delta = score_a == 0.0 ? -Inf :
                score_a == 1.0 ?  Inf :
                -400 * log10(1/score_a - 1)

    return (wins_a=wins_a, wins_b=wins_b, draws=draws,
            score_a=score_a, elo_delta=elo_delta)
end
