module Cassandra

using Bobby
using Flux
using JLD2
using JSON3
using Random

include("Board.jl")
include("Book.jl")
include("Config.jl")
include("Model/MoveIndex.jl")
include("Model/CassandraModel.jl")
include("Eval/NNEval.jl")
include("Eval/Classical.jl")
include("Search/TT.jl")
include("Search/MoveOrder.jl")
include("Search/AlphaBeta.jl")
include("Training/DataPipeline.jl")
include("Training/Imitation.jl")
include("Training/PGNData.jl")
include("Training/SelfPlay.jl")
include("Training/Trainer.jl")

export apply_moves, select_move, search, START_FEN, policy_info, material_eval
export Book
export set_max_depth!, get_max_depth, tt_clear!
export CassandraModel, build_model, build_conv_model, forward, save_model, load_model
export INPUT_SIZE, UCI_MOVES, UCI2IDX, N_MOVES
export DatasetWriter, write_record!, close_dataset, DatasetReader, batch_iterator, make_batch, random_batch
export RECORD_BYTES, RECORD_BYTES_V2
export prepare_puzzles, prepare_pgn
export TrainStats, train_epoch!
export play_game, evaluate
# Config
export EngineConfig, SearchConfig, EvalConfig, OrderingConfig, BookConfig
export get_engine_cfg, apply_engine_cfg!, load_engine_cfg, save_engine_cfg
export engine_cfg_to_dict, engine_cfg_from_dict, cfg_hash, ENGINE_CONFIG_SCHEMA
# Classical eval
export classical_eval

end # module Cassandra
