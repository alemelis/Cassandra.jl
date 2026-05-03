module Cassandra

using Bobby
using Flux
using JLD2
using JSON3
using Random

include("Board.jl")
include("Model/MoveIndex.jl")
include("Model/CassandraModel.jl")
include("Eval/NNEval.jl")
include("Search/TT.jl")
include("Search/MoveOrder.jl")
include("Search/AlphaBeta.jl")
include("Training/DataPipeline.jl")
include("Training/Imitation.jl")
include("Training/SelfPlay.jl")
include("Training/Trainer.jl")

export apply_moves, select_move, search, START_FEN, policy_info, material_eval
export set_max_depth!, get_max_depth
export CassandraModel, build_model, forward, save_model, load_model
export INPUT_SIZE, UCI_MOVES, UCI2IDX, N_MOVES
export DatasetWriter, write_record!, close_dataset, DatasetReader, batch_iterator, make_batch
export prepare_puzzles
export TrainStats, train_epoch!
export play_game, evaluate

end # module Cassandra
