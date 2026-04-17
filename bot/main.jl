using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using DotEnv
DotEnv.load!(joinpath(@__DIR__, ".env"))

using Bobby
using BongCloud
using Cassandra

const BOT_TOKEN = get(ENV, "LICHESS_TOKEN", "")
isempty(BOT_TOKEN) && error("Set LICHESS_TOKEN environment variable")

function handle_position(client::LichessClient, game_id::String,
                         fen::String, moves_str::String, my_color::Symbol)
    board = Cassandra.apply_moves(moves_str, fen)
    is_my_turn = (board.active && my_color == :white) ||
                 (!board.active && my_color == :black)
    is_my_turn || return

    move = Cassandra.select_move(board)
    if isnothing(move)
        @info "[$game_id] No legal moves — resigning"
        BongCloud.resign_game(client, game_id)
        return
    end
    @info "[$game_id] Playing $move"
    BongCloud.make_move(client, game_id, move)
end

function play_game(client::LichessClient, game_id::String, bot_name::String)
    @info "[$game_id] Game started"
    initial_fen = Ref(Cassandra.START_FEN)
    my_color    = Ref(:white)

    try
        for event in BongCloud.stream_game(client, game_id)
            if event isa BongCloud.GameFull
                fen = something(event.initialFen, Cassandra.START_FEN)
                fen == "startpos" && (fen = Cassandra.START_FEN)
                initial_fen[] = fen

                white_name = get(something(event.white, Dict{String,Any}()), "name", "")
                my_color[] = white_name == bot_name ? :white : :black
                @info "[$game_id] Playing as $(my_color[])"

                moves_str = String(get(something(event.state, Dict{String,Any}()), "moves", ""))
                handle_position(client, game_id, initial_fen[], moves_str, my_color[])

            elseif event isa BongCloud.GameState
                event.status != "started" && (@info "[$game_id] Game over: $(event.status)"; break)
                handle_position(client, game_id, initial_fen[], event.moves, my_color[])
            end
        end
    catch e
        @error "[$game_id] Error" exception=(e, catch_backtrace())
    end
end

function run()
    client = LichessClient(token=BOT_TOKEN)
    profile = BongCloud.get_profile(client)
    bot_name = profile["username"]
    @info "Bot online as $bot_name"

    for event in BongCloud.stream_events(client)
        if event.type == "challenge"
            ch = event.challenge
            variant = get(something(ch.variant, Dict{String,Any}()), "key", "standard")
            if variant == "standard"
                @info "Accepting challenge $(ch.id) from $(get(something(ch.challenger, Dict{String,Any}()), "name", "?"))"
                BongCloud.accept_challenge(client, ch.id)
            else
                @info "Declining non-standard challenge $(ch.id) (variant: $variant)"
                BongCloud.decline_challenge(client, ch.id; reason="variant")
            end

        elseif event.type == "gameStart"
            game_id = something(event.game.gameId, event.game.id)
            @async play_game(client, game_id, bot_name)
        end
    end
end

run()
