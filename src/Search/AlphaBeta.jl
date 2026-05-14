# Classical alpha-beta search with iterative deepening.
# PeSTO eval at leaves; killers/history/TT for ordering. No neural network.

const _ABORT_SCORE = 0f0

# ── Null-move helper ─────────────────────────────────────────────────────────
# Bobby has no built-in null move; we construct one by toggling the active side
# and clearing en-passant, with a fresh Zobrist hash.
@inline function _make_null_move(board::Bobby.Board)::Bobby.Board
    active = !board.active
    ep     = UInt64(0)
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

# Apply a null move (toggle side, clear EP) in-place; returns a 3-tuple for undo.
# Incremental hash: XOR out EP file key, XOR in "no EP", flip ZOBRIST_SIDE.
@inline function _apply_null_move!(board::Bobby.Board)
    prev_ep      = board.enpassant
    prev_hash    = board.hash
    prev_halfmove = board.halfmove

    h = prev_hash
    # Remove old EP key
    if prev_ep != Bobby.EMPTY
        h ⊻= @inbounds Bobby.ZOBRIST_EP[(trailing_zeros(prev_ep) % 8) + 1]
    else
        h ⊻= @inbounds Bobby.ZOBRIST_EP[9]
    end
    h ⊻= @inbounds Bobby.ZOBRIST_EP[9]   # new EP is EMPTY → slot 9
    h ⊻= Bobby.ZOBRIST_SIDE

    board.active    = !board.active
    board.enpassant = Bobby.EMPTY
    board.halfmove  = prev_halfmove + 1
    board.hash      = h

    return (prev_ep, prev_hash, prev_halfmove)
end

@inline function _undo_null_move!(board::Bobby.Board, prev_ep, prev_hash, prev_halfmove)
    board.active    = !board.active
    board.enpassant = prev_ep
    board.halfmove  = prev_halfmove
    board.hash      = prev_hash
end

# Check the system clock at most once every 1024 nodes to amortize VDSO overhead.
# The ~700μs worst-case overshoot at 1.4M NPS is acceptable for time management.
@inline time_exceeded(ctx::SearchContext, deadline::Float64) =
    (ctx.nodes & 0x3FF) == 0 && time() > deadline

# Compat shim used at the root level where ctx is not yet set up (deadline-only checks).
@inline time_exceeded(deadline::Float64) = time() > deadline

# Index into ctx.order_buf / score_buf for the given ply, clamped to the
# pre-allocated capacity. Quiescence search can extend the ply past MAX_PLY
# in rare deep capture chains — clamping is benign (we just reuse the last
# slot; correctness is unaffected because each call resize!'s the slot).
@inline _buf_slot(ply::Int) = clamp(ply + 1, 1, MAX_PLY + 2)

# ── Quiescence search ────────────────────────────────────────────────────────
function _qsearch(board::Bobby.Board, alpha::Float32, beta::Float32,
                  ply::Int, deadline::Float64, ctx::SearchContext,
                  cfg::EngineConfig)::Float32

    time_exceeded(ctx, deadline) && return _ABORT_SCORE
    ctx.nodes += 1

    stand_pat = classical_eval(board,
                               cfg.eval.bishop_pair_cp,
                               cfg.eval.rook_open_cp,
                               cfg.eval.rook_semi_cp)
    stand_pat >= beta  && return beta
    alpha = max(alpha, stand_pat)

    slot   = _buf_slot(ply)
    legal  = ctx.legal_buf[slot]
    Bobby.getMoves!(legal, ctx.scratch_buf[slot], ctx.pin_ray_buf[slot],
                   board, board.active)

    # Checkmate / stalemate detection (qsearch owns this for depth-0 leaf nodes).
    if isempty(legal.moves)
        return Bobby.inCheck(board, board.active) ?
               -(MATE_SCORE - Float32(ply)) : 0f0
    end

    order  = ctx.order_buf[slot]
    scores = ctx.score_buf[slot]
    order_moves!(order, scores, legal.moves, Int16(0),
                 (Int16(0), Int16(0)), EMPTY_HISTORY)

    delta_margin = Float32(cfg.search.delta_pruning_margin_cp)
    see_threshold = cfg.search.see_qsearch_threshold_cp

    for i in order
        m = legal.moves[i]
        is_capture = m.take.type != 0
        is_qpromo  = m.promotion == Bobby.PIECE_QUEEN
        (is_capture || is_qpromo) || continue

        if is_capture
            gain = _CAPTURE_VALS[Int(m.take.type) + 1]
            stand_pat + gain + delta_margin < alpha && continue
            # SEE filter: drop captures the swap evaluator deems losing.
            # Promotion-captures are kept regardless (SEE doesn't score
            # promotion gains).
            if m.promotion == 0 && see(board, m) < see_threshold
                continue
            end
        end

        undo  = Bobby.makeMove!(board, m)
        score = -_qsearch(board, -beta, -alpha, ply + 1, deadline, ctx, cfg)
        Bobby.unmakeMove!(board, undo)
        time_exceeded(ctx, deadline) && return _ABORT_SCORE

        score >= beta && return beta
        alpha = max(alpha, score)
    end

    return alpha
end

# ── Main negamax ─────────────────────────────────────────────────────────────
function _negamax(board::Bobby.Board, depth::Int,
                  alpha::Float32, beta::Float32,
                  ply::Int, deadline::Float64,
                  ctx::SearchContext,
                  cfg::EngineConfig)::Float32

    time_exceeded(ctx, deadline) && return _ABORT_SCORE

    # Repetition on search path → draw (path-only, bounded by halfmove)
    is_repetition(ctx, board.hash, board.halfmove) && return 0f0

    # TT probe
    tt_score, tt_best = tt_probe(board.hash, depth, ply, alpha, beta)
    tt_score !== nothing && return tt_score

    # Compute in_check early: needed for check extension before the depth check.
    # inCheck is fast (9 ns) and avoids calling getMoves! at depth-0 leaf nodes
    # where qsearch will generate moves anyway.
    in_check = Bobby.inCheck(board, board.active)

    # Check extension
    cfg.search.check_extension && in_check && (depth += 1)

    # Leaf node: hand off to qsearch (which owns checkmate detection) or eval.
    if depth <= 0
        cfg.search.qsearch && return _qsearch(board, alpha, beta, ply, deadline, ctx, cfg)
        return classical_eval(board, cfg.eval.bishop_pair_cp,
                              cfg.eval.rook_open_cp, cfg.eval.rook_semi_cp)
    end

    board.halfmove >= 100 && return 0f0

    slot  = _buf_slot(ply)
    legal = ctx.legal_buf[slot]
    Bobby.getMoves!(legal, ctx.scratch_buf[slot], ctx.pin_ray_buf[slot],
                   board, board.active)

    if isempty(legal.moves)
        return in_check ? -(MATE_SCORE - Float32(ply)) : 0f0
    end

    ctx.nodes += 1

    # Null-move pruning (skip in check, pawn-only endgames, PV nodes)
    pv_node = (beta - alpha) > 1f0
    if cfg.search.null_move_enabled && !in_check && !pv_node &&
       depth >= cfg.search.null_move_min_depth && _has_non_pawn(board)
        R = cfg.search.null_move_R
        prev_ep, prev_hash, prev_hm = _apply_null_move!(board)
        rep_push!(ctx, prev_hash)
        null_score = -_negamax(board, depth - 1 - R,
                               -beta, -beta + 1f0,
                               ply + 1, deadline, ctx, cfg)
        rep_pop!(ctx)
        _undo_null_move!(board, prev_ep, prev_hash, prev_hm)
        time_exceeded(ctx, deadline) && return _ABORT_SCORE
        null_score >= beta && return beta
    end

    # Move ordering
    killers = cfg.ordering.killers ? ctx.killers[min(ply + 1, MAX_PLY)] :
                                     (Int16(0), Int16(0))
    hist    = cfg.ordering.history ? ctx.history : EMPTY_HISTORY

    order  = ctx.order_buf[slot]
    scores = ctx.score_buf[slot]
    order_moves!(order, scores, legal.moves, tt_best, killers, hist)

    rep_push!(ctx, board.hash)

    orig_alpha = alpha
    best_score = -INF_SCORE
    best_idx   = order[1]
    aborted    = false

    for (move_num, i) in enumerate(order)
        m = legal.moves[i]
        undo = Bobby.makeMove!(board, m)

        # Late Move Reductions for quiet moves
        reduction = 0
        if cfg.search.lmr_enabled && !in_check && depth >= cfg.search.lmr_min_depth &&
           move_num > cfg.search.lmr_min_move_idx && m.take.type == 0 && m.promotion == 0
            reduction = cfg.search.lmr_reduction
        end

        child_score = -_negamax(board, depth - 1 - reduction,
                                -beta, -alpha,
                                ply + 1, deadline, ctx, cfg)

        # Re-search at full depth if LMR failed high
        if reduction > 0 && child_score > alpha && !time_exceeded(ctx, deadline)
            child_score = -_negamax(board, depth - 1,
                                    -beta, -alpha,
                                    ply + 1, deadline, ctx, cfg)
        end

        Bobby.unmakeMove!(board, undo)

        if time_exceeded(ctx, deadline)
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
                update_ordering!(ctx, m, Int16(i), ply, depth)
                break
            end
        end
    end

    rep_pop!(ctx)
    aborted && return _ABORT_SCORE

    flag = best_score <= orig_alpha ? TT_UPPER :
           best_score >= beta       ? TT_LOWER : TT_EXACT
    tt_store!(board.hash, depth, ply, best_score, flag, Int16(best_idx))

    return best_score
end

# ── Iterative-deepening root search ──────────────────────────────────────────
# `time_budget_ms`, when supplied, overrides `cfg.search.time_limit_s` for
# this call only (no global mutation — safe for concurrent games). The bot
# computes it from the live Lichess clock; offline tools leave it `nothing`.
function search(board::Bobby.Board;
                cfg::EngineConfig=get_engine_cfg(),
                time_budget_ms::Union{Nothing,Integer}=nothing)::Union{String,Nothing}
    scfg          = cfg.search
    budget_s      = time_budget_ms === nothing ?
                        scfg.time_limit_s :
                        max(Int(time_budget_ms), 1) / 1000.0
    deadline      = time() + budget_s
    ctx           = SearchContext()

    # Root uses the ply-0 slot of the pre-allocated buffers.
    root_legal = ctx.legal_buf[1]
    Bobby.getMoves!(root_legal, ctx.scratch_buf[1], ctx.pin_ray_buf[1],
                   board, board.active)
    isempty(root_legal.moves) && return nothing

    root_order  = ctx.order_buf[1]
    root_scores = ctx.score_buf[1]
    order_moves!(root_order, root_scores, root_legal.moves,
                 Int16(0), (Int16(0), Int16(0)), EMPTY_HISTORY)

    n_legal     = length(root_legal.moves)
    move_scores = Vector{Float32}(undef, n_legal)  # one alloc per search

    best_move  = root_legal.moves[root_order[1]]
    prev_score = 0f0

    for depth in 1:scfg.max_depth
        time_exceeded(deadline) && break
        reset_ctx!(ctx)

        window = Float32(scfg.aspiration_window_cp)
        lo     = window > 0f0 && depth > 1 ? prev_score - window : -INF_SCORE
        hi     = window > 0f0 && depth > 1 ? prev_score + window :  INF_SCORE

        iter_best_score = -INF_SCORE
        iter_best_idx   = root_order[1]
        timed_out       = false

        # Aspiration loop: widen and retry on fail-low / fail-high
        while true
            alpha = lo; beta = hi
            iter_best_score = -INF_SCORE
            iter_best_idx   = root_order[1]
            fill!(move_scores, -INF_SCORE)

            for i in root_order
                undo  = Bobby.makeMove!(board, root_legal.moves[i])
                score = -_negamax(board, depth - 1, -beta, -alpha,
                                  1, deadline, ctx, cfg)
                Bobby.unmakeMove!(board, undo)
                if time_exceeded(ctx, deadline)
                    timed_out = true
                    break
                end
                @inbounds move_scores[i] = score
                if score > iter_best_score
                    iter_best_score = score
                    iter_best_idx   = i
                end
                alpha = max(alpha, score)
            end

            timed_out && break

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
            winning_idx::Int16 = Int16(0)
            drawing_idx::Int16 = Int16(0)
            @inbounds for i in root_order
                s = move_scores[i]
                if s > 0f0 && winning_idx == 0
                    winning_idx = i
                elseif s == 0f0 && drawing_idx == 0
                    drawing_idx = i
                end
            end
            if winning_idx != 0
                iter_best_idx   = winning_idx
                iter_best_score = 1f0
            elseif drawing_idx != 0
                iter_best_idx   = drawing_idx
                iter_best_score = 0f0
            end
        end

        best_move  = root_legal.moves[iter_best_idx]
        prev_score = iter_best_score

        # Hoist the iteration's best move to the front of root_order without
        # reallocating: find its position, shift the prefix down, plant it at 1.
        @inbounds for k in 1:n_legal
            if root_order[k] == iter_best_idx
                for j in k:-1:2
                    root_order[j] = root_order[j-1]
                end
                root_order[1] = iter_best_idx
                break
            end
        end
    end

    return Bobby.moveToUCI(best_move)
end

# ── Bot entry point ──────────────────────────────────────────────────────────
# `time_budget_ms` is the per-move budget computed by the bot from the
# Lichess clock (see TimeBudget.compute_budget_ms). If `nothing`, falls back
# to `cfg.search.time_limit_s`. Book hits return instantly regardless of
# budget — "zap through the opening".
function select_move(board::Bobby.Board;
                     time_budget_ms::Union{Nothing,Integer}=nothing)::Union{String,Nothing}
    cfg = get_engine_cfg()
    if cfg.book.enabled && Book.enabled()
        bm = Book.probe(board)
        if bm !== nothing
            @info "[book] hit" hash=string(board.hash) move=bm
            return bm
        end
    end
    return search(board; cfg, time_budget_ms)
end
