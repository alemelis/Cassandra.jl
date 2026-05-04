using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Bobby
using BongCloud
using Cassandra
using Dates
using HTTP
using JSON3
using Random

const BOT_TOKEN = get(ENV, "LICHESS_TOKEN", "")
isempty(BOT_TOKEN) && error("Set LICHESS_TOKEN environment variable")

const CHECKPOINTS_DIR = get(ENV, "CHECKPOINTS_DIR", joinpath(@__DIR__, "..", "checkpoints"))
const LOGS_DIR        = get(ENV, "LOGS_DIR",        joinpath(@__DIR__, "..", "logs"))
const TRACES_DIR      = joinpath(LOGS_DIR, "game_traces")
const CONTROL_PORT    = parse(Int, get(ENV, "BOT_CONTROL_PORT", "8080"))

mkpath(LOGS_DIR)
mkpath(TRACES_DIR)

# ── Model state ───────────────────────────────────────────────────────────────

const MODEL_LOCK       = ReentrantLock()
const MODEL_REF        = Ref{Any}(nothing)
const RELOAD_PENDING   = Ref(false)
const CLIENT_REF       = Ref{Any}(nothing)
const ACTIVE_GAMES     = Set{String}()
const GAMES_LOCK       = ReentrantLock()
const OWN_RATING       = Ref{Union{Int,Nothing}}(nothing)

# ── Challenge state ───────────────────────────────────────────────────────────

const GAMES_PAUSED      = Ref(false)   # when true: decline all incoming challenges
const CHALLENGE_PAUSED  = Ref(false)
const PENDING_OUTGOING  = Dict{String,NamedTuple{(:target,:created_at),Tuple{String,DateTime}}}()
const PENDING_LOCK      = ReentrantLock()

# Track bots that have rate-limited us (429) with exponential backoff
const RATE_LIMITED_BOTS = Dict{String,DateTime}()
const RATE_LIMITED_LOCK = ReentrantLock()
const RATE_LIMIT_BACKOFF_BASE = 60
const RATE_LIMIT_MAX_BACKOFF  = 3600

const API_RATE_LIMITED_UNTIL = Ref{Union{DateTime,Nothing}}(nothing)
const API_RATE_LIMIT_LOCK = ReentrantLock()

function _is_api_rate_limited()
    API_RATE_LIMITED_UNTIL[] !== nothing && now() < API_RATE_LIMITED_UNTIL[]
end

function _mark_api_rate_limited(seconds::Int=120)
    lock(API_RATE_LIMIT_LOCK) do
        API_RATE_LIMITED_UNTIL[] = now() + Second(seconds)
    end
    @info "API rate limited for $seconds seconds"
end

function _is_rate_limited(target::String)
    lock(RATE_LIMITED_LOCK) do
        t = get(RATE_LIMITED_BOTS, target, nothing)
        t === nothing && return false
        now() < t ? true : false
    end
end

function _mark_rate_limited(target::String; backoff=RATE_LIMIT_BACKOFF_BASE)
    lock(RATE_LIMITED_LOCK) do
        current = get(RATE_LIMITED_BOTS, target, nothing)
        if current === nothing
            RATE_LIMITED_BOTS[target] = now() + Second(backoff)
        else
            new_backoff = min(backoff * 2, RATE_LIMIT_MAX_BACKOFF)
            RATE_LIMITED_BOTS[target] = now() + Second(new_backoff)
        end
    end
    @info "Rate limit backoff for $target"
end

const TC_ROTATION = [(60, 0), (60, 0), (180, 0), (180, 0), (180, 2), (180, 2), (600, 0), (600, 0)]
# 2x bullet (60+0), 2x blitz (180+0), 2x rapid (180+2), 2x classical (600+0)
const TC_INDEX    = Ref(1)

function _next_tc()
    tc = TC_ROTATION[TC_INDEX[]]
    TC_INDEX[] = mod1(TC_INDEX[] + 1, length(TC_ROTATION))
    tc
end

# Concurrency caps — engine speed dictates these
const MAX_GAMES         = parse(Int, get(ENV, "BOT_MAX_GAMES",     "2"))
const MAX_PENDING_OPENS = parse(Int, get(ENV, "BOT_MAX_OPENS",     "3"))
const TARGETED_PROB     = parse(Float64, get(ENV, "BOT_TARGETED_P", "0.25"))

# Arena auto-join state
const JOINED_ARENAS    = Set{String}()
const ARENA_BLACKLIST  = Set{String}()
const ARENA_LOCK       = ReentrantLock()

# ── Model loading ─────────────────────────────────────────────────────────────

function _load_model()
    path = joinpath(CHECKPOINTS_DIR, "deployed.jld2")
    if isfile(path)
        @info "Loading model from $path"
        Cassandra.load_model(path)
    else
        @info "No deployed model — building random model"
        Cassandra.build_model()
    end
end

function _read_deployed_meta()
    path = joinpath(LOGS_DIR, "deployed.json")
    isfile(path) || return nothing
    JSON3.read(read(path, String))
end

function _read_deployed_epoch()
    meta = _read_deployed_meta()
    meta === nothing && return nothing
    get(meta, :epoch, nothing)
end

function _game_intro()
    meta = _read_deployed_meta()
    meta === nothing && return nothing
    name = get(meta, :run_name, nothing)
    name === nothing && return nothing
    nickname = replace(string(name), "_" => " ")
    epoch = get(meta, :epoch, nothing)
    loss  = get(meta, :loss_policy, nothing)
    detail = if epoch !== nothing && loss !== nothing
        "epoch $(epoch), loss $(round(Float64(loss); digits=4))"
    elseif epoch !== nothing
        "epoch $(epoch)"
    else
        nothing
    end
    detail === nothing ? "$(nickname) · gl hf!" : "$(nickname) · $(detail) · gl hf!"
end

MODEL_REF[] = _load_model()

function current_model()
    lock(MODEL_LOCK) do
        MODEL_REF[]
    end
end

function swap_model_if_pending()
    RELOAD_PENDING[] || return
    @info "Reloading model after game"
    new_model = _load_model()
    lock(MODEL_LOCK) do
        MODEL_REF[] = new_model
        RELOAD_PENDING[] = false
    end
    @info "Model reloaded"
end

# ── Control server ────────────────────────────────────────────────────────────

function start_control_server()
    router = HTTP.Router()
    HTTP.register!(router, "POST", "/reload", function(req)
        client = CLIENT_REF[]
        if client === nothing
            RELOAD_PENDING[] = true
            @info "Reload queued (client not ready)"
            return HTTP.Response(200, "{\"ok\":true,\"queued\":true}")
        end
        active = lock(GAMES_LOCK) do; collect(ACTIVE_GAMES); end
        for gid in active
            try
                BongCloud.resign_game(client, gid)
                @info "Resigned $gid for model reload"
            catch e
                @warn "Could not resign $gid" exception=e
            end
        end
        new_model = _load_model()
        lock(MODEL_LOCK) do
            MODEL_REF[] = new_model
            RELOAD_PENDING[] = false
        end
        n = length(active)
        @info "Model reloaded ($n game$(n == 1 ? "" : "s") resigned)"
        return HTTP.Response(200, "{\"ok\":true,\"resigned\":$n}")
    end)
    HTTP.register!(router, "GET", "/health", function(req)
        return HTTP.Response(200, "{\"ok\":true}")
    end)
    HTTP.register!(router, "GET", "/challenge/status", function(req)
        paused = CHALLENGE_PAUSED[]
        return HTTP.Response(200, "{\"paused\":$paused}")
    end)
    HTTP.register!(router, "POST", "/challenge/pause", function(req)
        CHALLENGE_PAUSED[] = true
        @info "Outgoing challenges paused"
        return HTTP.Response(200, "{\"ok\":true,\"paused\":true}")
    end)
    HTTP.register!(router, "POST", "/challenge/resume", function(req)
        CHALLENGE_PAUSED[] = false
        @info "Outgoing challenges resumed"
        return HTTP.Response(200, "{\"ok\":true,\"paused\":false}")
    end)
    HTTP.register!(router, "GET", "/games/status", function(req)
        paused = GAMES_PAUSED[]
        return HTTP.Response(200, "{\"paused\":$paused}")
    end)
    HTTP.register!(router, "POST", "/games/pause", function(req)
        GAMES_PAUSED[] = true
        @info "Incoming games paused — will decline all challenges"
        return HTTP.Response(200, "{\"ok\":true,\"paused\":true}")
    end)
    HTTP.register!(router, "POST", "/games/resume", function(req)
        GAMES_PAUSED[] = false
        @info "Incoming games resumed"
        return HTTP.Response(200, "{\"ok\":true,\"paused\":false}")
    end)
    HTTP.register!(router, "GET", "/search/config", function(req)
        d = Cassandra.get_max_depth()
        return HTTP.Response(200, "{\"max_depth\":$d}")
    end)
    HTTP.register!(router, "POST", "/search/config", function(req)
        try
            obj = JSON3.read(String(req.body))
            d   = Int(obj.max_depth)
            Cassandra.set_max_depth!(d)
            new_d = Cassandra.get_max_depth()
            @info "Search max_depth set to $new_d"
            return HTTP.Response(200, "{\"ok\":true,\"max_depth\":$new_d}")
        catch e
            return HTTP.Response(400, "{\"ok\":false,\"error\":\"$(replace(string(e), "\""=>"\\\""))\"}")
        end
    end)
    @async HTTP.serve(router, "0.0.0.0", CONTROL_PORT; verbose=false)
    @info "Control server on :$CONTROL_PORT"
end

# ── Logging ───────────────────────────────────────────────────────────────────

const BOT_LOG = joinpath(LOGS_DIR, "bot_log.jsonl")

function log_game(game_id, result, color, opponent, opponent_rating)
    ts         = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
    meta       = _read_deployed_meta()
    epoch      = meta !== nothing ? get(meta, :epoch,    nothing) : nothing
    model_name = meta !== nothing ? get(meta, :run_name, nothing) : nothing
    epoch_field = epoch      !== nothing ? ",\"deployed_epoch\":$epoch"   : ""
    model_field = model_name !== nothing ? ",\"model\":\"$model_name\""   : ""
    opp_r = opponent_rating !== nothing ? opponent_rating : "null"
    line = """{"ts":"$ts","game_id":"$game_id","result":"$result","color":"$color","opponent":"$opponent","opponent_rating":$opp_r$epoch_field$model_field}"""
    open(BOT_LOG, "a") do io; println(io, line); end
end

# ── Challenge helpers ─────────────────────────────────────────────────────────

_active_game_count() = lock(GAMES_LOCK) do; length(ACTIVE_GAMES); end

function _pending_open_count()
    lock(PENDING_LOCK) do
        count(p -> p.second.target == "open", PENDING_OUTGOING)
    end
end

function _pending_direct_count()
    lock(PENDING_LOCK) do
        count(p -> p.second.target != "open", PENDING_OUTGOING)
    end
end

function _reap_pending()
    cutoff = now() - Second(45)
    lock(PENDING_LOCK) do
        for (id, info) in collect(PENDING_OUTGOING)
            if info.created_at < cutoff
                @info "Cancelling stale outgoing challenge $(id) → $(info.target)"
                try BongCloud.cancel_challenge(CLIENT_REF[], id) catch; end
                delete!(PENDING_OUTGOING, id)
            end
        end
    end
end

function _cancel_all_pending()
    lock(PENDING_LOCK) do
        for (id, _) in collect(PENDING_OUTGOING)
            try BongCloud.cancel_challenge(CLIENT_REF[], id) catch; end
        end
        empty!(PENDING_OUTGOING)
    end
end

# Direct single-shot challenge create — bypasses BongCloud's 429 retry loop
# (which wastes 5 API calls per attempt and drains the rate-limit bucket).
function _try_create_challenge(client::BongCloud.LichessClient, target::String,
                                limit::Int, inc::Int)
    url  = "https://lichess.org/api/challenge/$target"
    body = HTTP.escapeuri(Dict("rated"=>"true",
                               "clock.limit"=>string(limit),
                               "clock.increment"=>string(inc)))
    hdrs = merge(BongCloud.auth_headers(client),
                 Dict("Content-Type"=>"application/x-www-form-urlencoded"))
    resp = HTTP.request("POST", url, hdrs, body; status_exception=false)
    return resp.status, String(resp.body)
end

# Open challenge fallback — not subject to the per-user challenge rate limit.
# Returns the challenge id on success, nothing on failure.
function _try_open_challenge(client::BongCloud.LichessClient, limit::Int, inc::Int)
    url  = "https://lichess.org/api/challenge/open"
    body = HTTP.escapeuri(Dict("rated"=>"true",
                               "clock.limit"=>string(limit),
                               "clock.increment"=>string(inc)))
    hdrs = merge(BongCloud.auth_headers(client),
                 Dict("Content-Type"=>"application/x-www-form-urlencoded"))
    resp = HTTP.request("POST", url, hdrs, body; status_exception=false)
    if resp.status in (200, 201)
        try
            obj = JSON3.read(String(resp.body))
            return String(get(obj, :id, ""))
        catch; end
    end
    @warn "Open challenge failed: HTTP $(resp.status) $(first(String(resp.body), 100))"
    return nothing
end

# ── Challenge loop ────────────────────────────────────────────────────────────

function _perf_rating(user::Dict{String,Any})
    perfs = get(user, "perfs", nothing)
    perfs isa Dict || return nothing
    for tc in ("blitz", "bullet", "rapid", "classical")
        p = get(perfs, tc, nothing)
        p isa Dict || continue
        r = get(p, "rating", nothing)
        r !== nothing && return Int(r)
    end
    nothing
end

_bot_name(b) = string(get(b, :username, get(b, "username", "")))

function _eligible(b, my_name::String, my_rating)
    n = _bot_name(b)
    isempty(n) && return false
    n == my_name && return false
    my_rating === nothing && return true
    r = _perf_rating(b)
    r === nothing || abs(r - my_rating) <= 400
end

function _post_open(client::LichessClient)
    limit, inc = _next_tc()
    id = _try_open_challenge(client, limit, inc)
    if id !== nothing && !isempty(id)
        lock(PENDING_LOCK) do
            PENDING_OUTGOING[id] = (target="open", created_at=now())
        end
        @info "Open challenge $id ($(limit÷60)+$(inc))"
        return true
    end
    false
end

function _post_targeted(client::LichessClient, my_name::String)
    bots = try
        collect(BongCloud.get_online_bots(client))
    catch e
        e isa EOFError && return
        @warn "get_online_bots failed" exception=e
        return
    end
    isempty(bots) && return
    my_rating = OWN_RATING[]
    candidates = [b for b in bots if _eligible(b, my_name, my_rating) && !_is_rate_limited(_bot_name(b))]
    isempty(candidates) && return
    target = _bot_name(rand(candidates))
    limit, inc = _next_tc()
    status, body = _try_create_challenge(client, target, limit, inc)
    if status in (200, 201)
        @info "Challenged $target ($(limit÷60)+$(inc))"
    elseif status == 429
        _mark_rate_limited(target)
    elseif status >= 400
        @info "[$target] HTTP $status: $(first(body, 120))"
    end
end

function _cleanup_rate_limits()
    now_ts = now()
    lock(RATE_LIMITED_LOCK) do
        for (k, v) in collect(RATE_LIMITED_BOTS)
            now_ts >= v && delete!(RATE_LIMITED_BOTS, k)
        end
    end
    lock(API_RATE_LIMIT_LOCK) do
        API_RATE_LIMITED_UNTIL[] !== nothing && now_ts >= API_RATE_LIMITED_UNTIL[] && (API_RATE_LIMITED_UNTIL[] = nothing)
    end
end

function challenge_bot(client::LichessClient, my_name::String)
    try
        _is_api_rate_limited() && return
        _cleanup_rate_limits()
        while _pending_open_count() < MAX_PENDING_OPENS
            _post_open(client) || break
        end
        if _pending_direct_count() == 0 && rand() < TARGETED_PROB
            _post_targeted(client, my_name)
        end
    catch e
        @warn "Challenge loop error" exception=e
    end
end
end

function challenge_bot(client::LichessClient, my_name::String)
    try
        # Maintain a pool of open challenges across multiple TCs
        while _pending_open_count() < MAX_PENDING_OPENS
            _post_open(client) || break
        end

        # Sometimes also fire a targeted challenge if no direct challenge is in flight
        if _pending_direct_count() == 0 && rand() < TARGETED_PROB
            _post_targeted(client, my_name)
        end
    catch e
        @warn "Challenge loop error" exception=e
    end
end

# ── Arena auto-join ───────────────────────────────────────────────────────────

function _list_tournaments(client::LichessClient)
    url  = "https://lichess.org/api/tournament"
    hdrs = BongCloud.auth_headers(client)
    resp = HTTP.request("GET", url, hdrs; status_exception=false)
    resp.status == 200 || return nothing
    JSON3.read(String(resp.body))
end

function _arena_match(arena)
    name = lowercase(string(get(arena, :fullName, get(arena, :name, ""))))
    occursin("bot", name) || return false
    variant = string(get(get(arena, :variant, Dict()), :key, "standard"))
    variant == "standard" || return false
    clk = get(arena, :clock, Dict())
    limit = Int(get(clk, :limit, 0))
    # Skip ultra-bullet (<30s) and classical (>15min)
    30 <= limit <= 900
end

function _try_join_arena(client::LichessClient, arena)
    id = string(arena.id)
    skip = lock(ARENA_LOCK) do
        id in JOINED_ARENAS || id in ARENA_BLACKLIST
    end
    skip && return
    try
        BongCloud.join_arena(client, id)
        lock(ARENA_LOCK) do; push!(JOINED_ARENAS, id); end
        arena_name = get(arena, :fullName, get(arena, :name, ""))
        @info "Joined arena $id ($arena_name)"
    catch e
        lock(ARENA_LOCK) do; push!(ARENA_BLACKLIST, id); end
        @info "Skip arena $id ($(typeof(e)))"
    end
end

function arena_loop(client::LichessClient)
    while true
        try
            data = _list_tournaments(client)
            if data !== nothing
                started = get(data, :started, [])
                created = get(data, :created, [])
                for arena in vcat(collect(started), collect(created))
                    _arena_match(arena) && _try_join_arena(client, arena)
                end
                # Forget finished arenas so the IDs don't accumulate forever
                finished_ids = Set(string(a.id) for a in get(data, :finished, []))
                lock(ARENA_LOCK) do
                    for id in collect(JOINED_ARENAS)
                        id in finished_ids && delete!(JOINED_ARENAS, id)
                    end
                end
            end
        catch e
            @warn "Arena loop error" exception=e
        end
        sleep(120)
    end
end

# ── Game handling ─────────────────────────────────────────────────────────────

function handle_position(client::LichessClient, game_id::String,
                         fen::String, moves_str::String, my_color::Symbol)
    board = Cassandra.apply_moves(moves_str, fen)
    is_my_turn = (board.active && my_color == :white) ||
                 (!board.active && my_color == :black)
    is_my_turn || return

    model = current_model()
    move  = Cassandra.select_move(model, board)
    if isnothing(move)
        @info "[$game_id] No legal moves — resigning"
        BongCloud.resign_game(client, game_id)
        return
    end

    try
        n_prev = isempty(strip(moves_str)) ? 0 : length(split(moves_str))
        v, ent, top5 = Cassandra.policy_info(model, board)
        open(joinpath(TRACES_DIR, "$game_id.jsonl"), "a") do io
            JSON3.write(io, (ply=n_prev, moves_before=moves_str, move=move,
                             value=round(v; digits=4),
                             entropy=round(ent; digits=4), top5=top5))
            println(io)
        end
    catch e
        @warn "[$game_id] Trace write failed" exception=e
    end

    @info "[$game_id] Playing $move"
    BongCloud.make_move(client, game_id, move)
end

# TODO(BongCloud): opponentGone and other unknown game-stream event types crash
# the Channel producer in BongCloud.Bot._parse_game_event, causing play_game to
# abort with "Unknown game event type: opponentGone". Upstream fix needed.
function play_game(client::LichessClient, game_id::String, bot_name::String)
    @info "[$game_id] Game started"
    lock(GAMES_LOCK) do; push!(ACTIVE_GAMES, game_id); end
    initial_fen     = Ref(Cassandra.START_FEN)
    my_color        = Ref(:white)
    opponent_name   = Ref("?")
    opponent_rating = Ref{Union{Int,Nothing}}(nothing)

    try
        try
            for event in BongCloud.stream_game(client, game_id)
                if event isa BongCloud.GameFull
                    fen = something(event.initialFen, Cassandra.START_FEN)
                    fen == "startpos" && (fen = Cassandra.START_FEN)
                    initial_fen[] = fen

                    white = something(event.white, Dict{String,Any}())
                    black = something(event.black, Dict{String,Any}())
                    white_name = get(white, "name", "")
                    my_color[] = white_name == bot_name ? :white : :black

                    opp = my_color[] == :white ? black : white
                    opponent_name[]   = get(opp, "name", "?")
                    opponent_rating[] = get(opp, "rating", nothing)

                    @info "[$game_id] Playing as $(my_color[]) vs $(opponent_name[])"

                    try
                        open(joinpath(TRACES_DIR, "$game_id.jsonl"), "w") do io
                            JSON3.write(io, (type="header", initial_fen=initial_fen[],
                                             color=string(my_color[]),
                                             opponent=opponent_name[]))
                            println(io)
                        end
                    catch e
                        @warn "[$game_id] Trace header failed" exception=e
                    end

                    intro = _game_intro()
                    @info "[$game_id] Intro: $(something(intro, "(none)"))"
                    if intro !== nothing
                        try
                            BongCloud.send_chat(client, game_id, "player", intro)
                        catch e
                            @warn "[$game_id] Chat failed" exception=e
                        end
                    end

                    moves_str = String(get(something(event.state, Dict{String,Any}()), "moves", ""))
                    handle_position(client, game_id, initial_fen[], moves_str, my_color[])

                elseif event isa BongCloud.GameState
                    if event.status != "started"
                        result = if event.winner === nothing
                            "draw"
                        elseif (event.winner == "white") == (my_color[] == :white)
                            "win"
                        else
                            "loss"
                        end
                        @info "[$game_id] Game over: $(event.status) → $result"
                        log_game(game_id, result, string(my_color[]),
                                 opponent_name[], opponent_rating[])
                        break
                    end
                    handle_position(client, game_id, initial_fen[], event.moves, my_color[])
                end
            end
        catch e
            @error "[$game_id] Error" exception=(e, catch_backtrace())
        end
    finally
        lock(GAMES_LOCK) do; delete!(ACTIVE_GAMES, game_id); end
        swap_model_if_pending()
        try
            p = BongCloud.get_profile(CLIENT_REF[])
            OWN_RATING[] = _perf_rating(p)
        catch; end
    end
end

# ── Main loop ─────────────────────────────────────────────────────────────────

function _handle_event(client, event, bot_name)
    if event.type == "challenge"
        ch = event.challenge
        direction = something(ch.direction, "in")

        if direction != "in"
            # Outgoing challenge notification — only track if we don't already
            # know about it (we tag opens with target="open" at create time).
            dest_dict = something(ch.destUser, Dict{String,Any}())
            target = isempty(dest_dict) ? "open" : get(dest_dict, "name", "?")
            lock(PENDING_LOCK) do
                if !haskey(PENDING_OUTGOING, ch.id)
                    PENDING_OUTGOING[ch.id] = (target=target, created_at=now())
                end
            end
            @info "Outgoing challenge $(ch.id) → $target"
            return
        end

        # Incoming challenge
        variant = get(something(ch.variant, Dict{String,Any}()), "key", "standard")
        if GAMES_PAUSED[]
            challenger = get(something(ch.challenger, Dict{String,Any}()), "name", "?")
            @info "Declining $(ch.id) from $challenger — games paused"
            try BongCloud.decline_challenge(client, ch.id; reason="later") catch; end
        elseif variant != "standard"
            @info "Declining non-standard challenge $(ch.id) (variant: $variant)"
            try BongCloud.decline_challenge(client, ch.id; reason="variant") catch; end
        elseif _active_game_count() >= MAX_GAMES
            @info "Declining $(ch.id) — at game cap ($(MAX_GAMES))"
            try BongCloud.decline_challenge(client, ch.id; reason="later") catch; end
        else
            challenger = get(something(ch.challenger, Dict{String,Any}()), "name", "?")
            @info "Accepting challenge $(ch.id) from $challenger"
            try BongCloud.accept_challenge(client, ch.id) catch; end
        end

    elseif event.type == "challengeDeclined"
        ch = event.challenge
        if ch !== nothing
            dest = get(something(ch.destUser, Dict{String,Any}()), "name", "?")
            reason_key = something(ch.declineReasonKey, "unknown")
            @info "Challenge declined by $dest — $reason_key"
            lock(PENDING_LOCK) do; delete!(PENDING_OUTGOING, ch.id); end
        end

    elseif event.type == "challengeCanceled"
        ch = event.challenge
        if ch !== nothing
            lock(PENDING_LOCK) do; delete!(PENDING_OUTGOING, ch.id); end
            @info "Challenge $(ch.id) cancelled"
        end

    elseif event.type == "gameStart"
        game_id = something(event.game.gameId, event.game.id)
        @async play_game(client, game_id, bot_name)
    end
end

function run()
    start_control_server()

    client       = LichessClient(token=BOT_TOKEN)
    CLIENT_REF[] = client
    profile      = BongCloud.get_profile(client)
    bot_name     = profile["username"]
    OWN_RATING[] = _perf_rating(profile)
    @info "Bot online as $bot_name (rating: $(something(OWN_RATING[], "unrated")))"

    # Warmup: trigger JIT compilation before the first real game so the
    # opening move isn't slow enough to cause an abort.
    let board = Bobby.loadFen(Cassandra.START_FEN)
        Cassandra.select_move(current_model(), board)
        Cassandra.policy_info(current_model(), board)
    end
    @info "JIT warmup done"

    @async arena_loop(client)

    @async while true
        if !CHALLENGE_PAUSED[]
            _reap_pending()
            if _active_game_count() >= MAX_GAMES
                _cancel_all_pending()
            else
                challenge_bot(client, bot_name)
            end
        end
        sleep(rand(5:15))
    end

    # Reconnect loop: stream_events can drop on network hiccups.
    while true
        try
            for event in BongCloud.stream_events(client)
                _handle_event(client, event, bot_name)
            end
            @warn "Event stream ended — reconnecting in 5s"
        catch e
            @warn "Event stream error — reconnecting in 5s" exception=e
        end
        sleep(5)
    end
end

run()
