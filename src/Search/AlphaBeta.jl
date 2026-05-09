# Classical alpha-beta search with iterative deepening.
# No neural network in the hot path — classical eval at leaves, policy logits
# used only if ordering.use_policy_logits is set in the active EngineConfig.

const _ABORT_SCORE = 0f0

# ── Null-move helper ─────────────────────────────────────────────────────────
# Bobby has no built-in null move; we construct one by toggling the active side
# and clearing en-passant, with a fresh Zobrist hash.
@inline function _make_null_move(board::Bobby.Board)::Bobby.Board
    # Build a position where the other side moves without making a move.
    # We keep all pieces as-is, flip active, clear ep, bump halfmove.
    active = !board.active
    ep     = UInt64(0)
    # Recompute hash: flip side, remove old ep key if any
    h = Bobby.computeHash(Bobby.Board(board.white, board.black, board.taken,
                                      active, board.castling, ep,
                                      board.halfmove + 1, board.fullmove + 1,
                                      UInt64(0)))
    Bobby.Board(board.white, board.black, board.taken,
                active, board.castling, ep,
                board.halfmove + 1, board.fullmove + 1, h)
end

# True if position has enough non-pawn material for null-move to be safe
@inline function _has_non_pawn(board::Bobby.Board)::Bool
    side = board.active ? board.white : board.black
    (side.N | side.B | side.R | side.Q) != UInt64(0)
end

# ── Quiescence search ────────────────────────────────────────────────────────
function _qsearch(board::Bobby.Board, alpha::Float32, beta::Float32,
                  ply::Int, deadline::Float64, ctx::SearchContext,
                  cfg::EngineConfig)::Float32

    time() > deadline && return _ABORT_SCORE
    ctx.nodes += 1

    # Stand-pat
    stand_pat = classical_eval(board,
                               cfg.eval.bishop_pair_cp,
                               cfg.eval.rook_open_cp,
                               cfg.eval.rook_semi_cp)
    stand_pat >= beta  && return beta
    alpha = max(alpha, stand_pat)

    all_moves = Bobby.getMoves(board, board.active)
    order = Vector{Int16}()
    order_moves!(order, all_moves.moves, nothing, Int16(0),
                 (Int16(0), Int16(0)), ctx.history)

    delta_margin = Float32(cfg.search.delta_pruning_margin_cp)

    for i in order
        m = all_moves.moves[i]
        # Only captures and queen promotions
        is_capture   = m.take.type != 0
        is_qpromo    = m.promotion == Bobby.PIECE_QUEEN
        (is_capture || is_qpromo) || continue

        # Delta pruning: skip clearly losing captures
        if is_capture
            gain = _CAPTURE_VALS[Int(m.take.type) + 1]
            stand_pat + gain + delta_margin < alpha && continue
        end

        child = Bobby.makeMove(board, m)
        score = -_qsearch(child, -beta, -alpha, ply + 1, deadline, ctx, cfg)
        time() > deadline && return _ABORT_SCORE

        score >= beta  && return beta
        alpha = max(alpha, score)
    end

    return alpha
end

# ── Main negamax ─────────────────────────────────────────────────────────────
function _negamax(model::Union{CassandraModel,Nothing},
                  board::Bobby.Board, depth::Int,
                  alpha::Float32, beta::Float32,
                  ply::Int, deadline::Float64,
                  seen::Set{UInt64}, ctx::SearchContext,
                  cfg::EngineConfig)::Float32

    time() > deadline && return _ABORT_SCORE

    # Repetition on search path → draw
    board.hash in seen && return 0f0

    # TT probe
    tt_score, tt_best = tt_probe(board.hash, depth, ply, alpha, beta)
    tt_score !== nothing && return tt_score

    legal = Bobby.getMoves(board, board.active)

    if isempty(legal.moves)
        return Bobby.inCheck(board, board.active) ?
               -(MATE_SCORE - Float32(ply)) : 0f0
    end
    board.halfmove >= 100 && return 0f0

    in_check = Bobby.inCheck(board, board.active)

    # Check extension
    if cfg.search.check_extension && in_check
        depth += 1
    end

    if depth <= 0
        cfg.search.qsearch && return _qsearch(board, alpha, beta, ply, deadline, ctx, cfg)
        return classical_eval(board, cfg.eval.bishop_pair_cp,
                              cfg.eval.rook_open_cp, cfg.eval.rook_semi_cp)
    end

    ctx.nodes += 1

    # Null-move pruning (skip in check, pawn-only endgames, PV nodes)
    pv_node = (beta - alpha) > 1f0
    if cfg.search.null_move_enabled && !in_check && !pv_node &&
       depth >= cfg.search.null_move_min_depth && _has_non_pawn(board)
        null_board = _make_null_move(board)
        R = cfg.search.null_move_R
        push!(seen, board.hash)
        null_score = -_negamax(model, null_board, depth - 1 - R,
                               -beta, -beta + 1f0,
                               ply + 1, deadline, seen, ctx, cfg)
        delete!(seen, board.hash)
        if time() > deadline; return _ABORT_SCORE; end
        null_score >= beta && return beta
    end

    # Move ordering
    logits  = cfg.ordering.use_policy_logits && model !== nothing ?
              forward(model, board)[2] : nothing
    killers = cfg.ordering.killers ? ctx.killers[min(ply + 1, MAX_PLY)] :
                                     (Int16(0), Int16(0))
    hist    = cfg.ordering.history ? ctx.history : zeros(Int32, 7, 64)
    order   = Vector{Int16}()
    order_moves!(order, legal.moves, logits, tt_best, killers, hist)

    push!(seen, board.hash)

    orig_alpha = alpha
    best_score = -INF_SCORE
    best_idx   = order[1]
    aborted    = false

    for (move_num, i) in enumerate(order)
        m = legal.moves[i]
        child = Bobby.makeMove(board, m)

        # Late Move Reductions for quiet moves
        reduction = 0
        if cfg.search.lmr_enabled && !in_check && depth >= cfg.search.lmr_min_depth &&
           move_num > cfg.search.lmr_min_move_idx && m.take.type == 0 && m.promotion == 0
            reduction = cfg.search.lmr_reduction
        end

        child_score = -_negamax(model, child, depth - 1 - reduction,
                                -beta, -alpha,
                                ply + 1, deadline, seen, ctx, cfg)

        # Re-search at full depth if LMR failed high
        if reduction > 0 && child_score > alpha && !time_exceeded(deadline)
            child_score = -_negamax(model, child, depth - 1,
                                    -beta, -alpha,
                                    ply + 1, deadline, seen, ctx, cfg)
        end

        if time() > deadline
            aborted = true
            break
        end

        if child_score > best_score
            best_score = child_score
            best_idx   = i
        end
        if child_score > alpha
            alpha = child_score
            if alpha >= beta
                # Beta-cutoff: update killers and history
                update_ordering!(ctx, m, Int16(i), ply, depth)
                break
            end
        end
    end

    delete!(seen, board.hash)
    aborted && return _ABORT_SCORE

    flag = best_score <= orig_alpha ? TT_UPPER :
           best_score >= beta       ? TT_LOWER : TT_EXACT
    tt_store!(board.hash, depth, ply, best_score, flag, Int16(best_idx))

    return best_score
end

@inline time_exceeded(deadline::Float64) = time() > deadline

# ── Iterative-deepening root search ──────────────────────────────────────────
function search(model::Union{CassandraModel,Nothing}, board::Bobby.Board;
                cfg::EngineConfig=get_engine_cfg())::Union{String,Nothing}
    legal = Bobby.getMoves(board, board.active)
    isempty(legal.moves) && return nothing

    scfg     = cfg.search
    deadline = time() + scfg.time_limit_s
    ctx      = SearchContext()
    seen     = Set{UInt64}()

    logits = cfg.ordering.use_policy_logits && model !== nothing ?
             forward(model, board)[2] : nothing

    order = Vector{Int16}()
    order_moves!(order, legal.moves, logits, Int16(0), (Int16(0), Int16(0)), ctx.history)

    best_move  = legal.moves[order[1]]
    prev_score = 0f0

    for depth in 1:scfg.max_depth
        time() > deadline && break
        reset_ctx!(ctx)

        window = Float32(scfg.aspiration_window_cp)
        lo     = window > 0f0 && depth > 1 ? prev_score - window : -INF_SCORE
        hi     = window > 0f0 && depth > 1 ? prev_score + window :  INF_SCORE

        move_scores     = Dict{Int16,Float32}()
        iter_best_score = -INF_SCORE
        iter_best_idx   = order[1]
        timed_out       = false

        # Aspiration loop: widen and retry on fail-low / fail-high
        while true
            alpha = lo; beta = hi
            move_scores     = Dict{Int16,Float32}()
            iter_best_score = -INF_SCORE
            iter_best_idx   = order[1]

            for i in order
                child = Bobby.makeMove(board, legal.moves[i])
                score = -_negamax(model, child, depth - 1, -beta, -alpha,
                                  1, deadline, seen, ctx, cfg)
                if time() > deadline
                    timed_out = true
                    break
                end
                move_scores[i] = score
                if score > iter_best_score
                    iter_best_score = score
                    iter_best_idx   = i
                end
                alpha = max(alpha, score)
            end

            timed_out && break

            # Re-search with widened window on aspiration failure
            if window > 0f0
                if iter_best_score <= lo
                    lo = -INF_SCORE; continue
                elseif iter_best_score >= hi
                    hi = INF_SCORE;  continue
                end
            end
            break
        end

        timed_out && break

        # Prefer drawing over losing when no winning move found
        if iter_best_score <= 0f0
            winning = Int16[]; drawing = Int16[]
            for (i, s) in move_scores
                s > 0f0  && push!(winning, i)
                s == 0f0 && push!(drawing, i)
            end
            if !isempty(winning)
                iter_best_idx   = winning[1]
                iter_best_score = 1f0
            elseif !isempty(drawing)
                iter_best_idx   = drawing[1]
                iter_best_score = 0f0
            end
        end

        best_move  = legal.moves[iter_best_idx]
        prev_score = iter_best_score
        filter!(x -> x != iter_best_idx, order)
        pushfirst!(order, iter_best_idx)
    end

    return Bobby.moveToUCI(best_move)
end

# ── Bot entry point ──────────────────────────────────────────────────────────
function select_move(model::Union{CassandraModel,Nothing},
                     board::Bobby.Board)::Union{String,Nothing}
    cfg = get_engine_cfg()
    if cfg.book.enabled && Book.enabled()
        bm = Book.probe(board)
        if bm !== nothing
            @info "[book] hit" hash=string(board.hash) move=bm
            return bm
        end
    end
    return search(model, board; cfg)
end
