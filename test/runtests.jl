using Test
using Cassandra
import Bobby

@testset "Cassandra.jl" begin

    @testset "Board" begin
        board = Cassandra.apply_moves("")
        @test board isa Bobby.Board

        # one move from start
        board2 = Cassandra.apply_moves("e2e4")
        @test board2 isa Bobby.Board
        @test board2 != board
    end

    @testset "Model" begin
        model = Cassandra.build_model()
        @test model isa Cassandra.CassandraModel

        board = Cassandra.apply_moves("")
        x = Cassandra.board_to_input(board)
        @test length(x) == Cassandra.INPUT_SIZE

        val, logits = Cassandra.forward(model, board)
        @test val isa Float32
        @test -1f0 <= val <= 1f0
        @test length(logits) == Cassandra.N_MOVES
    end

    @testset "MoveIndex" begin
        @test Cassandra.N_MOVES == 1924
        @test haskey(Cassandra.UCI2IDX, "e2e4")
        @test Cassandra.UCI2IDX["e2e4"] >= 1
    end

    @testset "Search" begin
        model = Cassandra.build_model()
        board = Cassandra.apply_moves("")
        move = Cassandra.select_move(model, board)
        @test move isa String
        @test length(move) in (4, 5)   # uci: e2e4 or e7e8q
    end

    @testset "DataPipeline round-trip" begin
        # build a tiny puzzle CSV and verify prepare_puzzles → DatasetReader
        csv_path = tempname() * ".csv"
        bin_path = tempname() * ".bin"

        open(csv_path, "w") do io
            println(io, "PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,Themes,GameUrl,OpeningTags")
            fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQK2R w KQkq - 0 1"
            board = Bobby.loadFen(fen)
            moves1 = Bobby.getMoves(board, board.active).moves
            for (i, m1) in enumerate(moves1)
                uci1 = Bobby.moveToUCI(m1)
                b2   = Bobby.makeMove(board, m1)
                for m2 in Bobby.getMoves(b2, b2.active).moves
                    uci2 = Bobby.moveToUCI(m2)
                    get(Cassandra.UCI2IDX, uci2, 0) == 0 && continue
                    println(io, "p$i,$fen,$uci1 $uci2,1500,80,90,100,tactics,https://lichess.org/p$i,")
                    break
                end
            end
        end

        n = Cassandra.prepare_puzzles(csv_path, bin_path)
        @test n > 0

        reader = Cassandra.DatasetReader(bin_path)
        @test reader.n_records == n

        tensors, values, policies = Cassandra.make_batch(reader, [1])
        @test size(tensors) == (Cassandra.INPUT_SIZE, 1)
        @test values[1] == 0f0
        @test 1 <= policies[1] <= Cassandra.N_MOVES

        rm(csv_path); rm(bin_path); rm(bin_path * ".json")
    end

    @testset "train_epoch! smoke" begin
        # write a 4-record dataset and run one epoch
        bin_path = tempname() * ".bin"
        writer   = Cassandra.DatasetWriter(bin_path)
        board    = Cassandra.apply_moves("")
        tensor   = Cassandra.board_to_input(board)
        for _ in 1:4
            Cassandra.write_record!(writer, tensor, 0f0, 1)
        end
        Cassandra.close_dataset(writer)

        import Flux
        model     = Cassandra.build_model()
        opt_state = Flux.setup(Flux.Adam(1f-3), model)
        stats     = Cassandra.train_epoch!(model, opt_state, bin_path;
                                           batch_size=2, epoch=1)
        @test stats isa Cassandra.TrainStats
        @test stats.n_batches == 2
        @test isfinite(stats.loss_policy)

        rm(bin_path); rm(bin_path * ".json")
    end

end
