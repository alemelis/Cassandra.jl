module Cassandra

using Bobby
using Random

# Search
include("Search/TT.jl")
include("Search/MoveOrder.jl")
include("Search/AlphaBeta.jl")

# Eval
include("Eval/Classical.jl")
include("Eval/NNEval.jl")

# Training
include("Training/DataPipeline.jl")
include("Training/Imitation.jl")
include("Training/SelfPlay.jl")
include("Training/Trainer.jl")

export select_move, apply_moves, apply_uci_move

end # module Cassandra
