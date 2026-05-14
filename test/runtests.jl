using Test
using Cassandra
import Bobby

@testset "Cassandra.jl" begin

    @testset "Board" begin
        board = Cassandra.apply_moves("")
        @test board isa Bobby.Board
        @test Cassandra.apply_moves("e2e4") != board
    end

    @testset "Classical eval" begin
        @test Cassandra.classical_eval(Cassandra.apply_moves("")) isa Float32
    end

    @testset "Search" begin
        move = Cassandra.select_move(Cassandra.apply_moves(""))
        @test move isa String
        @test length(move) in (4, 5)   # uci: e2e4 or e7e8q
    end

    @testset "Config round-trip" begin
        cfg = Cassandra.EngineConfig(name="test")
        d   = Cassandra.engine_cfg_to_dict(cfg)
        cfg2 = Cassandra.engine_cfg_from_dict(d)
        @test cfg2.name == "test"
        @test cfg2.search.max_depth == cfg.search.max_depth
    end

    @testset "Polyglot hash (golden vectors)" begin
        # python-chess test.py — canonical polyglot Zobrist hashes.
        # Each entry: (FEN, expected hash).
        vectors = [
            ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                0x463b96181691fc9c),
            ("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
                0x823c9b50fd114196),
            ("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
                0x0756b94461c50fb0),
            ("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2",
                0x662fafb965db29d4),
            ("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3",
                0x22a48b5a8e47ff78),
            ("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPPKPPP/RNBQ1BNR b kq - 1 3",
                0x652a607ca3f242c1),
            ("rnbq1bnr/ppp1pkpp/8/3pPp2/8/8/PPPPKPPP/RNBQ1BNR w - - 2 4",
                0x00fdd303c946bdd9),
            ("rnbqkbnr/p1pppppp/8/8/PpP4P/8/1P1PPPP1/RNBQKBNR b KQkq c3 0 3",
                0x3c8123ea7b067637),
            ("rnbqkbnr/p1pppppp/8/8/P6P/R1p5/1P1PPPP1/1NBQKBNR b Kkq - 1 4",
                0x5c3f9b829b279560),
        ]
        for (fen, expected) in vectors
            h = Cassandra.PolyglotBook.polyglot_hash(Bobby.loadFen(fen))
            @test h == expected
        end
    end
end
