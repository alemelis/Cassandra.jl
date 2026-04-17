const INPUT_SIZE = 8 * 8 * Bobby.N_PLANES  # 1280

struct CassandraModel
    trunk::Flux.Chain
    value_head::Flux.Chain
    policy_head::Flux.Chain
end

Flux.@functor CassandraModel (trunk, value_head, policy_head)

function build_model()
    trunk = Flux.Chain(
        Flux.Dense(INPUT_SIZE => 256, Flux.relu),
        Flux.Dense(256 => 128, Flux.relu),
    )
    value_head = Flux.Chain(
        Flux.Dense(128 => 32, Flux.relu),
        Flux.Dense(32 => 1, tanh),
        vec,
    )
    policy_head = Flux.Chain(
        Flux.Dense(128 => N_MOVES),
    )
    return CassandraModel(trunk, value_head, policy_head)
end

function (m::CassandraModel)(x::AbstractVecOrMat)
    h = m.trunk(x)
    return m.value_head(h), m.policy_head(h)
end

function board_to_input(board::Bobby.Board)::Vector{Float32}
    buf = zeros(Float32, 8, 8, Bobby.N_PLANES)
    Bobby.board_to_tensor!(buf, board)
    return vec(buf)
end

function forward(m::CassandraModel, board::Bobby.Board)
    x = board_to_input(board)
    value_vec, logits = m(x)
    return Float32(only(value_vec)), logits
end

function save_model(path::AbstractString, model::CassandraModel)
    JLD2.jldsave(path; trunk=Flux.state(model.trunk),
                       value_head=Flux.state(model.value_head),
                       policy_head=Flux.state(model.policy_head))
end

function load_model(path::AbstractString)::CassandraModel
    m = build_model()
    JLD2.jldopen(path, "r") do f
        Flux.loadmodel!(m.trunk,       f["trunk"])
        Flux.loadmodel!(m.value_head,  f["value_head"])
        Flux.loadmodel!(m.policy_head, f["policy_head"])
    end
    return m
end
