const INPUT_SIZE = 8 * 8 * Bobby.N_PLANES  # 1280

struct CassandraModel
    trunk::Flux.Chain
    value_head::Flux.Chain
    policy_head::Flux.Chain
    arch::NamedTuple
end

# Only trunk/value_head/policy_head contain trainable parameters.
Flux.@layer CassandraModel trainable=(trunk, value_head, policy_head)

# ── Shared forward ────────────────────────────────────────────────────────────

function (m::CassandraModel)(x::AbstractVecOrMat)
    h = m.trunk(x)
    return m.value_head(h), m.policy_head(h)
end

# ── Stateless reshape layer (flat → 8×8×C×N) ─────────────────────────────────

struct _InputReshape end
# No @layer — stateless, no trainable params. Treat as Functors leaf.
(_::_InputReshape)(x) = reshape(x, 8, 8, Bobby.N_PLANES, :)

# ── Residual block ────────────────────────────────────────────────────────────

struct _ResBlock
    conv1::Flux.Conv
    bn1::Flux.BatchNorm
    conv2::Flux.Conv
    bn2::Flux.BatchNorm
end
Flux.@layer _ResBlock

function (rb::_ResBlock)(x)
    h = Flux.relu.(rb.bn1(rb.conv1(x)))
    h = rb.bn2(rb.conv2(h))
    Flux.relu.(h .+ x)
end

function _resblock(c::Int)
    _ResBlock(
        Flux.Conv((3, 3), c => c; pad=Flux.SamePad()),
        Flux.BatchNorm(c),
        Flux.Conv((3, 3), c => c; pad=Flux.SamePad()),
        Flux.BatchNorm(c),
    )
end

# ── Conv-residual model (arch_version = 2) ────────────────────────────────────

"""
    build_conv_model(; n_channels=48, n_blocks=4) → CassandraModel

Small conv-residual tower for CPU training.
Input: flat vector (1280,) or matrix (1280, B).
Trunk: reshape to (8,8,20,B) → stem Conv 3×3 (20→C) → N residual blocks.
Policy head: Conv 1×1 (C→16) → flatten → Dense(1024 → N_MOVES).
Value head:  Conv 1×1 (C→4)  → flatten → Dense(256 → 64, relu) → Dense(64 → 1, tanh).
"""
function build_conv_model(; n_channels::Int=32, n_blocks::Int=2)::CassandraModel
    C = n_channels
    trunk_layers = Any[
        _InputReshape(),
        Flux.Conv((3, 3), Bobby.N_PLANES => C; pad=Flux.SamePad()),
        Flux.BatchNorm(C),
        x -> Flux.relu.(x),
    ]
    for _ in 1:n_blocks
        push!(trunk_layers, _resblock(C))
    end
    trunk = Flux.Chain(trunk_layers...)

    policy_head = Flux.Chain(
        Flux.Conv((1, 1), C => 16),
        Flux.flatten,
        Flux.Dense(16 * 64 => N_MOVES),
    )

    value_head = Flux.Chain(
        Flux.Conv((1, 1), C => 4),
        Flux.flatten,
        Flux.Dense(4 * 64 => 64, Flux.relu),
        Flux.Dense(64 => 1, tanh),
        vec,
    )

    arch = (arch_version=2, n_channels=C, n_blocks=n_blocks)
    CassandraModel(trunk, value_head, policy_head, arch)
end

# ── MLP model (arch_version = 1, kept for old checkpoints) ───────────────────

"""
    build_model(; trunk_sizes, dropout) → CassandraModel

Flat MLP. Retained so old checkpoints can still be loaded.
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

    arch = (arch_version=1, trunk_sizes=trunk_sizes, dropout=dropout)
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
    arch = (arch_version=0, trunk_sizes=[256, 128], dropout=0f0)
    return CassandraModel(trunk, value_head, policy_head, arch)
end

# ── Board → input ─────────────────────────────────────────────────────────────

@inline _fresh_buf() = Array{Float32,3}(undef, 8, 8, Bobby.N_PLANES)

function board_to_input!(buf::Array{Float32,3}, board::Bobby.Board)
    Bobby.board_to_tensor!(buf, board)
    return vec(buf)
end

board_to_input(board::Bobby.Board) = board_to_input!(_fresh_buf(), board)

function forward(m::CassandraModel, board::Bobby.Board, buf::Array{Float32,3}=_fresh_buf())
    x = board_to_input!(buf, board)
    value_vec, logits = m(x)
    # vec ensures a 1D float32 vector for callers (e.g. MoveOrder) that expect Vector{Float32}.
    # For batch calls (m(matrix)) callers use the raw output directly.
    return Float32(only(value_vec)), vec(logits)
end

# ── Persistence ───────────────────────────────────────────────────────────────

function save_model(path::AbstractString, model::CassandraModel;
                    meta::Union{Nothing,Dict}=nothing)
    a = model.arch
    av = get(a, :arch_version, 0)
    kw = Dict{Symbol,Any}(
        :meta => something(meta, Dict{String,Any}()),
    )
    if av == 2
        kw[:arch_version_conv] = Int32(2)
        kw[:arch_n_channels]   = Int32(a.n_channels)
        kw[:arch_n_blocks]     = Int32(a.n_blocks)
    else
        kw[:arch_trunk_sizes]  = collect(Int32, get(a, :trunk_sizes, [256, 128]))
        kw[:arch_dropout]      = Float32(get(a, :dropout, 0f0))
    end
    kw[:trunk]       = Flux.state(model.trunk)
    kw[:value_head]  = Flux.state(model.value_head)
    kw[:policy_head] = Flux.state(model.policy_head)
    JLD2.jldsave(path; kw...)
end

# Returns (model, meta::Dict{String,Any}).  meta is empty if none was embedded.
function load_model(path::AbstractString)::Tuple{CassandraModel,Dict{String,Any}}
    JLD2.jldopen(path, "r") do f
        m = if haskey(f, "arch_version_conv") && Int(f["arch_version_conv"]) == 2
            build_conv_model(;
                n_channels = Int(f["arch_n_channels"]),
                n_blocks   = Int(f["arch_n_blocks"]))
        elseif haskey(f, "arch_trunk_sizes")
            build_model(;
                trunk_sizes = Vector{Int}(f["arch_trunk_sizes"]),
                dropout     = Float32(f["arch_dropout"]))
        else
            _build_legacy_model()
        end
        Flux.loadmodel!(m.trunk,        f["trunk"])
        Flux.loadmodel!(m.value_head,   f["value_head"])
        Flux.loadmodel!(m.policy_head,  f["policy_head"])
        meta = haskey(f, "meta") ? Dict{String,Any}(f["meta"]) : Dict{String,Any}()
        m, meta
    end
end
