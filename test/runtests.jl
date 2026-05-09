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
end
