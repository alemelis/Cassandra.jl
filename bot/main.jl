using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using BongCloud
using Cassandra
using Dates
using HTTP
using JSON3
using Random

const BOT_TOKEN = get(ENV, "LICHESS_TOKEN", "")
isempty(BOT_TOKEN) && error("Set LICHESS_TOKEN environment variable")

const LOGS_DIR     = get(ENV, "LOGS_DIR",   joinpath(@__DIR__, "..", "logs"))
const SETUPS_DIR   = get(ENV, "SETUPS_DIR", joinpath(@__DIR__, "..", "setups"))
const TRACES_DIR   = joinpath(LOGS_DIR, "game_traces")
const CONTROL_PORT = parse(Int, get(ENV, "BOT_CONTROL_PORT", "8080"))
const CONFIG_PATH  = joinpath(LOGS_DIR, "bot_config.json")
const QUOTA_PATH   = joinpath(LOGS_DIR, "bot_quota.json")
const BOT_LOG_PATH = joinpath(LOGS_DIR, "bot_log.jsonl")

mkpath(LOGS_DIR); mkpath(TRACES_DIR); mkpath(SETUPS_DIR)

# ── Matchmaker config ────────────────────────────────────────────────────────
# Engine knobs (depth, eval, search, book) live in setups/deployed.json.
# This file holds only matchmaker preferences.

const TC_OPTIONS = [
    ("15s+0", (15,   0)),  # ultra-bullet
    ("30s+0", (30,   0)),  # ultra-bullet
    ("1+0",   (60,   0)),  # bullet
    ("1+1",   (60,   1)),  # bullet
    ("2+1",   (120,  1)),  # bullet
    ("3+0",   (180,  0)),  # bullet
    ("3+2",   (180,  2)),  # blitz
    ("5+0",   (300,  0)),  # blitz
    ("5+3",   (300,  3)),  # blitz
    ("10+0",  (600,  0)),  # rapid
    ("10+5",  (600,  5)),  # rapid
    ("15+10", (900, 10)),  # rapid
]
const TC_LABELS   = String[t[1] for t in TC_OPTIONS]
const TC_BY_LABEL = Dict(t[1] => t[2] for t in TC_OPTIONS)

const CONFIG_LOCK = ReentrantLock()
const CONFIG = Ref(Dict{String,Any}(
    "paused"                    => false,
    "rating_low"                => -400,
    "rating_high"               => 1000,
    "daily_quota"               => 100,
    "min_challenge_gap_seconds" => 60,
    "enabled_tcs"               => copy(TC_LABELS),
))

function next_tc()
    raw = lock(CONFIG_LOCK) do; get(CONFIG[], "enabled_tcs", TC_LABELS); end
    labels = String[String(x) for x in raw if haskey(TC_BY_LABEL, String(x))]
    isempty(labels) && (labels = TC_LABELS)
    TC_BY_LABEL[rand(labels)]
end

enabled_tc_summary() = let raw = lock(CONFIG_LOCK) do; get(CONFIG[], "enabled_tcs", TC_LABELS); end
    labels = String[String(x) for x in raw if haskey(TC_BY_LABEL, String(x))]
    isempty(labels) ? "all" : join(labels, ",")
end

function load_config!()
    isfile(CONFIG_PATH) || return
    lock(CONFIG_LOCK) do
        merge!(CONFIG[], JSON3.read(read(CONFIG_PATH, String), Dict{String,Any}))
    end
end

function save_config()
    lock(CONFIG_LOCK) do
        open(CONFIG_PATH, "w") do io; JSON3.write(io, CONFIG[]); end
    end
end

cfg(k) = lock(CONFIG_LOCK) do; CONFIG[][k]; end

function patch_config!(updates::Dict)
    lock(CONFIG_LOCK) do
        merge!(CONFIG[], updates)
    end
    save_config()
end

# ── Engine setup (single source of truth: setups/deployed.json) ─────────────

const SETUP_LOCK = ReentrantLock()
const SETUP_META = Ref{Dict{String,Any}}(Dict{String,Any}())

_deployed_setup_path() = joinpath(SETUPS_DIR, "deployed.json")

function load_engine_setup!()
    path = _deployed_setup_path()
    if isfile(path)
        c = Cassandra.load_engine_cfg(path)
        Cassandra.apply_engine_cfg!(c)
        lock(SETUP_LOCK) do
            SETUP_META[] = Dict{String,Any}("name" => c.name, "hash" => Cassandra.cfg_hash(c))
        end
        @info "[setup] Loaded" name=c.name
    else
        c = Cassandra.get_engine_cfg()
        Cassandra.save_engine_cfg(c, path)
        lock(SETUP_LOCK) do
            SETUP_META[] = Dict{String,Any}("name" => c.name, "hash" => Cassandra.cfg_hash(c))
        end
        @info "[setup] No deployed.json — using defaults, wrote $path"
    end
end

current_setup_meta() = lock(SETUP_LOCK) do; copy(SETUP_META[]); end

# ── Daily quota ───────────────────────────────────────────────────────────────

const QUOTA_LOCK  = ReentrantLock()
const QUOTA_DATE  = Ref(today())
const QUOTA_COUNT = Ref(0)

function load_quota!()
    isfile(QUOTA_PATH) || return
    lock(QUOTA_LOCK) do
        obj = JSON3.read(read(QUOTA_PATH, String))
        d = try Date(string(obj[:date])) catch; Date(0, 1, 1) end
        d == today() && (QUOTA_DATE[] = d; QUOTA_COUNT[] = Int(obj[:count]))
    end
end

quota_count()   = lock(QUOTA_LOCK) do; QUOTA_DATE[] == today() ? QUOTA_COUNT[] : 0; end
quota_reached() = quota_count() >= Int(cfg("daily_quota"))

function increment_quota!()
    lock(QUOTA_LOCK) do
        QUOTA_DATE[] == today() || (QUOTA_DATE[] = today(); QUOTA_COUNT[] = 0)
        QUOTA_COUNT[] += 1
        open(QUOTA_PATH, "w") do io
            JSON3.write(io, (date=string(QUOTA_DATE[]), count=QUOTA_COUNT[]))
        end
    end
end

# ── Runtime state ─────────────────────────────────────────────────────────────

const CLIENT_REF       = Ref{Any}(nothing)
const OWN_NAME         = Ref{String}("")
const OWN_RATING       = Ref{Union{Int,Nothing}}(nothing)
const IN_GAME          = Ref(false)
const CURRENT_GAME_ID  = Ref{Union{String,Nothing}}(nothing)
const CURRENT_OPPONENT = Ref{String}("")
const PENDING_ID       = Ref{Union{String,Nothing}}(nothing)

const LOCKOUT_LOCK  = ReentrantLock()
const LOCKOUT_UNTIL = Ref{Union{DateTime,Nothing}}(nothing)

const SKIPLIST      = Dict{String,DateTime}()
const SKIPLIST_LOCK = ReentrantLock()

const PREV_MOVES = Dict{String,String}()

# ── Lockout ───────────────────────────────────────────────────────────────────

in_lockout() = lock(LOCKOUT_LOCK) do
    LOCKOUT_UNTIL[] !== nothing && now() < LOCKOUT_UNTIL[]
end

function set_lockout!(s::Int)
    t = now() + Second(s)
    lock(LOCKOUT_LOCK) do; LOCKOUT_UNTIL[] = t; end
    @warn "Rate-limited for $(s)s (until $t)"
end

lockout_remaining() = lock(LOCKOUT_LOCK) do
    LOCKOUT_UNTIL[] === nothing && return 0
    max(0, round(Int, (LOCKOUT_UNTIL[] - now()).value / 1000))
end

# ── Skiplist (24h per-bot cooldown after decline/error) ───────────────────────

skip!(target::String) = lock(SKIPLIST_LOCK) do
    SKIPLIST[target] = now() + Hour(24)
end

skipped(target::String) = lock(SKIPLIST_LOCK) do
    t = get(SKIPLIST, target, nothing)
    t === nothing && return false
    now() >= t ? (delete!(SKIPLIST, target); false) : true
end

# ── Pacing (self-pace to land ≈daily_quota games/day) ────────────────────────

function pacing_interval()
    quota      = Int(cfg("daily_quota"))
    games_left = max(1, quota - quota_count())
    midnight   = DateTime(today() + Day(1))
    secs_left  = max(1, round(Int, (midnight - now()).value / 1000))
    max(div(secs_left, games_left), Int(cfg("min_challenge_gap_seconds")))
end

# ── Candidate targets ─────────────────────────────────────────────────────────

function _perf_rating(user)
    perfs = get(user, "perfs", nothing)
    perfs === nothing && return nothing
    for tc in ("blitz", "bullet", "rapid", "classical")
        p = get(perfs, tc, nothing)
        p === nothing && continue
        r = get(p, "rating", nothing)
        r !== nothing && return Int(r)
    end
    nothing
end

function pick_target(client)
    bots = try collect(BongCloud.get_online_bots(client; nb=200))
    catch e; @warn "get_online_bots failed" exception=e; return nothing; end

    my_name = OWN_NAME[]
    lo, hi  = Int(cfg("rating_low")), Int(cfg("rating_high"))
    my_r    = OWN_RATING[]

    candidates = filter(bots) do b
        n = get(b, "username", "")
        isempty(n) && return false
        lowercase(n) == lowercase(my_name) && return false
        skipped(n) && return false
        my_r === nothing && return true
        r = _perf_rating(b)
        r === nothing && return true
        lo <= (r - my_r) <= hi
    end

    isempty(candidates) && return nothing
    get(rand(candidates), "username", nothing)
end

# ── Logging ───────────────────────────────────────────────────────────────────

function log_game(game_id, result, color, opponent, opponent_rating, tc)
    setup = current_setup_meta()
    rec   = Dict{String,Any}(
        "ts"              => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
        "game_id"         => game_id,
        "result"          => result,
        "color"           => color,
        "opponent"        => opponent,
        "opponent_rating" => opponent_rating,
    )
    tc !== nothing && (rec["clock_limit"] = tc[1]; rec["clock_increment"] = tc[2])
    if !isempty(setup)
        rec["setup_name"] = get(setup, "name", "")
        rec["setup_hash"] = get(setup, "hash", "")
    end
    open(BOT_LOG_PATH, "a") do io; JSON3.write(io, rec); println(io); end
end

# ── Game ──────────────────────────────────────────────────────────────────────

function handle_position(client, game_id, fen, moves_str, my_color)
    board      = Cassandra.apply_moves(moves_str, fen)
    is_my_turn = (board.active && my_color == :white) || (!board.active && my_color == :black)
    is_my_turn || return

    move = Cassandra.select_move(board)
    if isnothing(move)
        @info "[$game_id] No legal moves — resigning"
        BongCloud.resign_game(client, game_id)
        return
    end

    try
        n    = isempty(strip(moves_str)) ? 0 : length(split(moves_str))
        prev = get(PREV_MOVES, game_id, "")
        opp_move = ""
        if !isempty(prev) && !isempty(moves_str)
            pw, cw = split(strip(prev)), split(strip(moves_str))
            length(cw) > length(pw) && (opp_move = cw[length(pw)+1])
        end
        PREV_MOVES[game_id] = isempty(moves_str) ? string(move) : moves_str * " " * string(move)
        trace_entry = (ply=n, moves_before=moves_str, move=move,
                       opponent_move=isempty(opp_move) ? nothing : opp_move)
        open(joinpath(TRACES_DIR, "$game_id.jsonl"), "a") do io
            JSON3.write(io, trace_entry); println(io)
        end
    catch e
        @warn "[$game_id] Trace write failed" exception=e
    end

    @info "[$game_id] Playing $move"
    BongCloud.make_move(client, game_id, move)
end

function play_game(client, game_id)
    @info "[$game_id] Game started"
    initial_fen     = Ref(Cassandra.START_FEN)
    my_color        = Ref(:white)
    opponent_name   = Ref("?")
    opponent_rating = Ref{Union{Int,Nothing}}(nothing)
    game_tc         = Ref{Union{Tuple{Int,Int},Nothing}}(nothing)

    try
        for event in BongCloud.stream_game(client, game_id)
            if event isa BongCloud.GameFull
                fen = something(event.initialFen, Cassandra.START_FEN)
                fen == "startpos" && (fen = Cassandra.START_FEN)
                initial_fen[] = fen

                white = something(event.white, Dict{String,Any}())
                black = something(event.black, Dict{String,Any}())
                wname = string(get(white, "name", ""))
                my_color[] = lowercase(wname) == lowercase(OWN_NAME[]) ? :white : :black
                opp = my_color[] == :white ? black : white
                opponent_name[]    = string(get(opp, "name", "?"))
                r = get(opp, "rating", nothing)
                opponent_rating[]  = r !== nothing ? Int(r) : nothing
                CURRENT_OPPONENT[] = opponent_name[]

                clk = something(event.clock, Dict{String,Any}())
                lim, inc = get(clk, "initial", 0), get(clk, "increment", 0)
                Int(lim) > 0 && (game_tc[] = (div(Int(lim), 1000), div(Int(inc), 1000)))

                @info "[$game_id] Playing as $(my_color[]) vs $(opponent_name[])"

                try
                    open(joinpath(TRACES_DIR, "$game_id.jsonl"), "w") do io
                        JSON3.write(io, (type="header", initial_fen=initial_fen[],
                            color=string(my_color[]), opponent=opponent_name[]))
                        println(io)
                    end
                catch e; @warn "[$game_id] Trace header failed" exception=e; end

                state_dict = something(event.state, Dict{String,Any}())
                handle_position(client, game_id, initial_fen[],
                    String(get(state_dict, "moves", "")), my_color[])

            elseif event isa BongCloud.GameState
                if event.status != "started"
                    result = if event.winner === nothing
                        "draw"
                    elseif (string(event.winner) == "white") == (my_color[] == :white)
                        "win"
                    else
                        "loss"
                    end
                    @info "[$game_id] Game over: $(event.status) → $result"
                    log_game(game_id, result, string(my_color[]),
                             opponent_name[], opponent_rating[], game_tc[])
                    break
                end
                handle_position(client, game_id, initial_fen[], event.moves, my_color[])
            end
        end
    catch e
        @error "[$game_id] Error" exception=(e, catch_backtrace())
    finally
        IN_GAME[]          = false
        CURRENT_GAME_ID[]  = nothing
        CURRENT_OPPONENT[] = ""
        delete!(PREV_MOVES, game_id)
        try
            p = BongCloud.get_profile(CLIENT_REF[])
            OWN_RATING[] = _perf_rating(p)
        catch; end
    end
end

# ── Event handler ─────────────────────────────────────────────────────────────

function handle_event(client, event)
    if event.type == "gameStart"
        game = event.game; game === nothing && return
        game_id = string(something(game.gameId, game.id, ""))
        isempty(game_id) && return
        if IN_GAME[]
            @warn "gameStart $game_id but already in a game — ignoring"
            return
        end
        PENDING_ID[]      = nothing
        IN_GAME[]         = true
        CURRENT_GAME_ID[] = game_id
        increment_quota!()
        @async play_game(client, game_id)

    elseif event.type == "challenge"
        ch = event.challenge; ch === nothing && return
        direction = something(ch.direction, "in")
        direction == "out" && return

        id         = ch.id
        challenger = string(get(something(ch.challenger, Dict()), "name",
                                get(something(ch.challenger, Dict()), :name, "?")))
        lowercase(challenger) == lowercase(OWN_NAME[]) && return
        variant    = string(get(something(ch.variant, Dict()), "key",
                                get(something(ch.variant, Dict()), :key, "standard")))

        reason = if Bool(cfg("paused"))        ; "later"
               elseif IN_GAME[]                ; "later"
               elseif PENDING_ID[] !== nothing ; "later"
               elseif quota_reached()          ; "later"
               elseif variant != "standard"    ; "variant"
               else                              nothing
               end

        if reason !== nothing
            @info "Declining $id from $challenger ($reason)"
            try BongCloud.decline_challenge(client, id; reason=reason) catch; end
        else
            @info "Accepting $id from $challenger"
            try BongCloud.accept_challenge(client, id) catch e @warn "Accept failed" exception=e end
        end

    elseif event.type == "challengeDeclined"
        ch = event.challenge; ch === nothing && return
        dest = string(get(something(ch.destUser, Dict()), "name",
                          get(something(ch.destUser, Dict()), :name, "")))
        @info "Challenge declined by $dest — $(something(ch.declineReasonKey, "unknown"))"
        isempty(dest) || skip!(dest)
        PENDING_ID[] = nothing

    elseif event.type == "challengeCanceled"
        ch = event.challenge; ch === nothing && return
        @info "Challenge $(ch.id) cancelled"
        PENDING_ID[] = nothing
    end
end

# ── Matchmaker (one challenge at a time, self-paced) ──────────────────────────

const CHALLENGE_TTL = 60

function matchmaker_loop(client)
    while true
        sleep(pacing_interval())
        Bool(cfg("paused"))      && continue
        IN_GAME[]                && continue
        quota_reached()          && (sleep(60); continue)
        in_lockout()             && (sleep(lockout_remaining() + 1); continue)
        PENDING_ID[] !== nothing && continue

        target = pick_target(client)
        target === nothing && (@warn "No eligible targets"; sleep(30); continue)

        lim, inc = next_tc()

        cid = try
            resp = BongCloud.create_challenge(client, target;
                rated=true, clock_limit=lim, clock_increment=inc, color="random")
            id = get(resp, "id", get(resp, :id, nothing))
            id !== nothing ? string(id) : nothing
        catch e
            msg = string(e)
            if   occursin("429", msg); set_lockout!(120)
            elseif occursin("40",  msg); skip!(target)
            end
            @warn "Challenge to $target failed" exception=e
            nothing
        end

        cid === nothing && continue
        PENDING_ID[] = cid
        @info "Challenged $target ($(lim÷60)+$inc) id=$cid"

        deadline = now() + Second(CHALLENGE_TTL)
        while PENDING_ID[] == cid && now() < deadline
            sleep(2)
        end

        if PENDING_ID[] == cid
            PENDING_ID[] = nothing
            skip!(target)
            @info "Challenge $cid timed out — cancelling"
            try BongCloud.cancel_challenge(client, cid) catch; end
        end
    end
end

# ── Control server ────────────────────────────────────────────────────────────

function start_control_server()
    router = HTTP.Router()

    HTTP.register!(router, "GET", "/status", function(req)
        body = JSON3.write((
            paused          = Bool(cfg("paused")),
            in_game         = IN_GAME[],
            opponent        = CURRENT_OPPONENT[],
            game_id         = CURRENT_GAME_ID[],
            games_today     = quota_count(),
            daily_quota     = Int(cfg("daily_quota")),
            lockout_seconds = lockout_remaining(),
            setup           = get(current_setup_meta(), "name", ""),
            max_depth       = Cassandra.get_max_depth(),
            rating          = OWN_RATING[],
            enabled_tcs     = enabled_tc_summary(),
            tc_options      = TC_LABELS,
        ))
        HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end)

    HTTP.register!(router, "GET", "/config", function(req)
        HTTP.Response(200, ["Content-Type" => "application/json"],
            lock(CONFIG_LOCK) do; JSON3.write(CONFIG[]); end)
    end)

    HTTP.register!(router, "POST", "/config", function(req)
        try
            patch_config!(JSON3.read(String(req.body), Dict{String,Any}))
            HTTP.Response(200, ["Content-Type" => "application/json"],
                lock(CONFIG_LOCK) do; JSON3.write(CONFIG[]); end)
        catch e
            HTTP.Response(400, "{\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "POST", "/pause",  req -> (patch_config!(Dict{String,Any}("paused" => true));  HTTP.Response(200, "{\"ok\":true}")))
    HTTP.register!(router, "POST", "/resume", req -> (patch_config!(Dict{String,Any}("paused" => false)); HTTP.Response(200, "{\"ok\":true}")))

    HTTP.register!(router, "POST", "/reload", function(req)
        client = CLIENT_REF[]; gid = CURRENT_GAME_ID[]
        gid !== nothing && client !== nothing &&
            try BongCloud.resign_game(client, gid) catch; end
        load_engine_setup!()
        HTTP.Response(200, "{\"ok\":true}")
    end)

    HTTP.register!(router, "GET", "/health", req -> HTTP.Response(200, "{\"ok\":true}"))

    HTTP.register!(router, "GET", "/engine_config", req ->
        HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON3.write(Cassandra.engine_cfg_to_dict(Cassandra.get_engine_cfg()))))

    HTTP.register!(router, "GET", "/engine_config/schema", req ->
        HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON3.write(Cassandra.ENGINE_CONFIG_SCHEMA)))

    HTTP.register!(router, "POST", "/engine_config", function(req)
        try
            d   = JSON3.read(String(req.body), Dict{String,Any})
            cfg = Cassandra.engine_cfg_from_dict(d)
            Cassandra.apply_engine_cfg!(cfg)
            Cassandra.save_engine_cfg(cfg, _deployed_setup_path())
            lock(SETUP_LOCK) do
                SETUP_META[] = Dict{String,Any}("name" => cfg.name, "hash" => Cassandra.cfg_hash(cfg))
            end
            HTTP.Response(200, ["Content-Type" => "application/json"],
                JSON3.write(Cassandra.engine_cfg_to_dict(cfg)))
        catch e
            HTTP.Response(400, "{\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "GET", "/book", function(req)
        entries = Cassandra.Book.list_entries()
        body = JSON3.write((
            count   = length(entries),
            path    = Cassandra.Book.BOOK_PATH[],
            entries = [(hash=e.hash, moves=e.moves) for e in entries],
        ))
        HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end)

    HTTP.register!(router, "POST", "/book/line", function(req)
        try
            data = JSON3.read(String(req.body))
            Cassandra.Book.add_line!(String(data.name), String(data.moves))
            Cassandra.Book.save!()
            HTTP.Response(200, "{\"ok\":true}")
        catch e
            HTTP.Response(400, "{\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "POST", "/book/entry/delete", function(req)
        try
            data = JSON3.read(String(req.body))
            Cassandra.Book.delete_entry!(String(data.hash), String(data.move))
            Cassandra.Book.save!()
            HTTP.Response(200, "{\"ok\":true}")
        catch e
            HTTP.Response(400, "{\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "POST", "/book/import", function(req)
        try
            Cassandra.Book.import_curated!()
            Cassandra.Book.save!()
            n = length(Cassandra.Book.list_entries())
            HTTP.Response(200, "{\"ok\":true,\"count\":$n}")
        catch e
            HTTP.Response(500, "{\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "POST", "/book/clear", function(req)
        Cassandra.Book.clear!()
        Cassandra.Book.save!()
        HTTP.Response(200, "{\"ok\":true}")
    end)

    @async HTTP.serve(router, "0.0.0.0", CONTROL_PORT; verbose=false)
    @info "Control server on :$CONTROL_PORT"
end

# ── Main ──────────────────────────────────────────────────────────────────────

function run()
    load_config!(); load_quota!(); load_engine_setup!()
    start_control_server()

    client = BongCloud.LichessClient(token=BOT_TOKEN)
    CLIENT_REF[] = client

    profile      = BongCloud.get_profile(client)
    OWN_NAME[]   = string(profile["username"])
    OWN_RATING[] = _perf_rating(profile)
    @info "Bot online as $(OWN_NAME[]) (rating: $(something(OWN_RATING[], "unrated")))"

    # JIT warmup of the search hot path
    Cassandra.select_move(Cassandra.apply_moves(""))
    @info "JIT warmup done"

    @async matchmaker_loop(client)

    while true
        try
            for event in BongCloud.stream_events(client)
                handle_event(client, event)
            end
            @warn "Event stream ended — reconnecting in 5s"
        catch e
            @warn "Event stream error — reconnecting in 5s" exception=e
        end
        sleep(5)
    end
end

run()
