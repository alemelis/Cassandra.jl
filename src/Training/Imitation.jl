"""
    prepare_puzzles(csv_path, output_path; max_puzzles=typemax(Int)) → Int

Reads the Lichess puzzle CSV and writes a binary dataset file.
Returns the number of records written.

Skips puzzles where:
- FEN fails to parse
- Setup move is illegal
- Correct answer UCI string is not in UCI2IDX
"""
function prepare_puzzles(csv_path::AbstractString,
                         output_path::AbstractString;
                         max_puzzles::Int=typemax(Int))::Int
    writer = DatasetWriter(output_path)
    buf = Array{Float32,3}(undef, 8, 8, Bobby.N_PLANES)
    skipped = 0

    open(csv_path) do io
        readline(io)  # skip header
        for line in eachline(io)
            writer.count >= max_puzzles && break

            fields = split(line, ',')
            length(fields) < 4 && (skipped += 1; continue)

            fen = String(fields[2])
            moves_str = String(fields[3])

            uci_list = split(moves_str)
            length(uci_list) < 2 && (skipped += 1; continue)

            board = try
                Bobby.loadFen(fen)
            catch
                skipped += 1; continue
            end

            setup = try
                Bobby.uciMoveToMove(board, String(uci_list[1]))
            catch
                skipped += 1; continue
            end
            board = Bobby.makeMove(board, setup)

            answer_uci = String(uci_list[2])
            policy_idx = get(UCI2IDX, answer_uci, 0)
            policy_idx == 0 && (skipped += 1; continue)

            tensor = board_to_input!(buf, board)
            write_record!(writer, tensor, 0f0, policy_idx)
        end
    end

    close_dataset(writer)
    n = writer.count
    @info "prepare_puzzles done" records=n skipped=skipped path=output_path
    return n
end
