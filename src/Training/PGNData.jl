"""
    prepare_pgn(pgn_path, output_path; min_elo, max_games, sample_every, result_decay) → Int

Reads a PGN file (optionally .zst compressed) and writes a v3 binary dataset.
Returns the number of records written.

One record per sampled position:
- policy = move actually played (index via UCI2IDX)
- value  = game result from the side-to-move perspective, with optional decay:
    value = result_sign * tanh(result_decay * plies_remaining + ε)
  Set result_decay = 0 for hard ±1/0 labels; default 0.05 gives ~±0.95 near
  the end and ~±0.05 far from the result.
- sample_weight = 1.0 (PGN games always weighted equally)

Skips games where both players are below `min_elo`, where the game has no
result tag (*, undefined), or where a move fails to parse.
"""
function prepare_pgn(pgn_path::AbstractString,
                     output_path::AbstractString;
                     min_elo::Int=2000,
                     max_games::Int=typemax(Int),
                     sample_every::Int=4,
                     result_decay::Float32=0.05f0)::Int
    writer  = DatasetWriter(output_path)
    buf     = Array{Float32,3}(undef, 8, 8, Bobby.N_PLANES)
    skipped = 0
    n_games = 0

    open_fn = endswith(pgn_path, ".zst") ? _zst_open : open

    open_fn(pgn_path) do io
        for (headers, uci_moves) in Bobby.read_pgn(io)
            n_games >= max_games && break

            # Filter by Elo
            w_elo = try parse(Int, get(headers, "WhiteElo", "0")) catch; 0 end
            b_elo = try parse(Int, get(headers, "BlackElo", "0")) catch; 0 end
            max(w_elo, b_elo) < min_elo && (skipped += 1; continue)

            # Parse result
            result_str = get(headers, "Result", "*")
            result_val::Float32 = if result_str == "1-0"
                1f0       # white wins
            elseif result_str == "0-1"
                -1f0      # black wins
            elseif result_str == "1/2-1/2"
                0f0       # draw
            else
                skipped += 1; continue   # unknown / abandoned
            end

            isempty(uci_moves) && (skipped += 1; continue)
            n_total = length(uci_moves)

            board = Bobby.setBoard()
            ok = true
            for (ply, uci) in enumerate(uci_moves)
                # board.active == true → white to move; value sign relative to STM
                stm_sign = board.active ? 1f0 : -1f0
                stm_result = stm_sign * result_val

                # Sample positions after move 8 (skip pure opening theory)
                # and every sample_every plies.
                if ply > 16 && (ply % sample_every == 0)
                    policy_idx = get(UCI2IDX, uci, 0)
                    if policy_idx != 0
                        legal = Bobby.getMoves(board, board.active)
                        legal_idxs = Int[]
                        for m in legal.moves
                            idx = get(UCI2IDX, Bobby.moveToUCI(m), 0)
                            idx != 0 && push!(legal_idxs, idx)
                        end
                        if policy_idx in legal_idxs
                            plies_left = n_total - ply
                            if result_decay > 0 && stm_result != 0f0
                                # Decay from result: positions far from end are labelled less confidently.
                                value = stm_result * tanh(result_decay * Float32(plies_left))
                            else
                                value = stm_result
                            end
                            legal_mask = build_legal_mask(legal_idxs)
                            tensor     = board_to_input!(buf, board)
                            write_record!(writer, tensor, value, policy_idx, legal_mask, 1f0)
                        end
                    end
                end

                # Advance board
                move = try Bobby.uciMoveToMove(board, uci) catch; ok = false; break end
                board = Bobby.makeMove(board, move)
            end

            ok ? (n_games += 1) : (skipped += 1)
        end
    end

    close_dataset(writer)
    n = writer.count
    @info "prepare_pgn done" games=n_games records=n skipped=skipped path=output_path
    return n
end

# Fallback: plain open for non-compressed files (already handled above).
# For .zst: requires CodecZstd.jl.  If not available, error with a clear message.
function _zst_open(f, path::AbstractString)
    try
        @eval using CodecZstd
        open(f, CodecZstd.ZstdDecompressorStream, path)
    catch e
        if isa(e, ArgumentError) || isa(e, UndefVarError)
            error("$path is .zst compressed but CodecZstd.jl is not installed. " *
                  "Run `Pkg.add(\"CodecZstd\")` or decompress the file first.")
        end
        rethrow()
    end
end
