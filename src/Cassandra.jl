module Cassandra

using Bobby
using Flux
using JLD2
using Random

# Search
include("Search/TT.jl")
include("Search/MoveOrder.jl")
include("Search/AlphaBeta.jl")

# Eval
include("Eval/Classical.jl")
include("Eval/NNEval.jl")

# Model
include("Model/MoveIndex.jl")
include("Model/CassandraModel.jl")

# Training
include("Training/DataPipeline.jl")
include("Training/Imitation.jl")
include("Training/SelfPlay.jl")
include("Training/Trainer.jl")

export select_move, apply_moves, apply_uci_move
export CassandraModel, build_model, forward, save_model, load_model
export UCI_MOVES, UCI2IDX, N_MOVES
export DatasetWriter, write_record!, close_dataset, DatasetReader, batch_iterator
export TrainStats, train_epoch!
export play_game, evaluate

end # module Cassandra
