const INPUT_SIZE = 8 * 8 * Bobby.N_PLANES  # 1280

struct CassandraModel
    trunk::Flux.Chain
    value_head::Flux.Chain
    policy_head::Flux.Chain
    arch::NamedTuple
end

# Only trunk/value_head/policy_head contain trainable parameters.
Flux.@layer CassandraModel trainable=(trunk, value_head, policy_head)

"""
    build_model(; trunk_sizes, dropout) → CassandraModel

Builds a fresh dual-headed network.

- Input is always INPUT_SIZE (fixed by board representation).
- Outputs are always N_MOVES logits + 1 scalar value (fixed by task).
- trunk_sizes: width of each trunk layer, e.g. [512, 256, 128].
  INPUT_SIZE → trunk_sizes[1] → trunk_sizes[2] → … (all with relu).
- value head:  last_width → last_width÷4 → 1 (tanh)
- policy head: last_width → N_MOVES        (linear)
"""
function build_model(; trunk_sizes::Vector{Int}=[256, 128],
                       dropout::Float32=0f0)::CassandraModel
    isempty(trunk_sizes)    && error("trunk_sizes must be non-empty")
    any(s -> s < 1, trunk_sizes) && error("all trunk widths must be >= 1")

    layers = Any[Flux.Dense(INPUT_SIZE => trunk_sizes[1], Flux.relu)]
    dropout > 0 && push!(layers, Flux.Dropout(Float64(dropout)))
    for i in 2:length(trunk_sizes)
        push!(layers, Flux.Dense(trunk_sizes[i-1] => trunk_sizes[i], Flux.relu))
        dropout > 0 && push!(layers, Flux.Dropout(Float64(dropout)))
    end
    trunk = Flux.Chain(layers...)

    last_w     = trunk_sizes[end]
    head_width = max(32, last_w ÷ 4)
    value_head = Flux.Chain(
        Flux.Dense(last_w => head_width, Flux.relu),
        Flux.Dense(head_width => 1, tanh),
        vec,
    )
    policy_head = Flux.Chain(Flux.Dense(last_w => N_MOVES))

    arch = (trunk_sizes=trunk_sizes, dropout=dropout)
    return CassandraModel(trunk, value_head, policy_head, arch)
end

# Exact replica of the original hardcoded architecture — used only for
# loading checkpoints that predate the parametric build_model.
function _build_legacy_model()::CassandraModel
    trunk = Flux.Chain(
        Flux.Dense(INPUT_SIZE => 256, Flux.relu),
        Flux.Dense(256 => 128, Flux.relu),
    )
    value_head = Flux.Chain(
        Flux.Dense(128 => 32, Flux.relu),
        Flux.Dense(32 => 1, tanh),
        vec,
    )
    policy_head = Flux.Chain(Flux.Dense(128 => N_MOVES))
    arch = (trunk_sizes=[256, 128], dropout=0f0)
    return CassandraModel(trunk, value_head, policy_head, arch)
end

@inline _fresh_buf() = Array{Float32,3}(undef, 8, 8, Bobby.N_PLANES)

function board_to_input!(buf::Array{Float32,3}, board::Bobby.Board)
    Bobby.board_to_tensor!(buf, board)
    return vec(buf)
end

board_to_input(board::Bobby.Board) = board_to_input!(_fresh_buf(), board)

function (m::CassandraModel)(x::AbstractVecOrMat)
    h = m.trunk(x)
    return m.value_head(h), m.policy_head(h)
end

function forward(m::CassandraModel, board::Bobby.Board, buf::Array{Float32,3}=_fresh_buf())
    x = board_to_input!(buf, board)
    value_vec, logits = m(x)
    return Float32(only(value_vec)), logits
end

function save_model(path::AbstractString, model::CassandraModel)
    a = model.arch
    JLD2.jldsave(path;
        trunk      = Flux.state(model.trunk),
        value_head = Flux.state(model.value_head),
        policy_head= Flux.state(model.policy_head),
        arch_trunk_sizes = collect(Int32, a.trunk_sizes),
        arch_dropout     = Float32(a.dropout))
end

function load_model(path::AbstractString)::CassandraModel
    JLD2.jldopen(path, "r") do f
        m = if haskey(f, "arch_trunk_sizes")
            build_model(;
                trunk_sizes = Vector{Int}(f["arch_trunk_sizes"]),
                dropout     = Float32(f["arch_dropout"]))
        else
            _build_legacy_model()
        end
        Flux.loadmodel!(m.trunk,        f["trunk"])
        Flux.loadmodel!(m.value_head,   f["value_head"])
        Flux.loadmodel!(m.policy_head,  f["policy_head"])
        m
    end
end
