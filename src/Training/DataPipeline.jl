import Mmap

# Binary dataset formats:
#
# v2 (legacy, 5380 bytes/record):
#   Float32[INPUT_SIZE]  board tensor
#   Float32              value target
#   Int64                policy_idx
#   UInt64[N_MASK_WORDS] legal-move bitmask
#
# v3 (current, 5384 bytes/record) — everything in v2 plus:
#   Float32              sample weight (0..1, for weighted loss)
#
# Sidecar: <path>.json with metadata including "version" key.
# v1 datasets (no bitmask) are rejected; v2 are read with weight=1.0.

const N_MASK_WORDS  = cld(N_MOVES, 64)              # 31 for N_MOVES=1924
const MASK_BYTES    = N_MASK_WORDS * sizeof(UInt64)  # 248
const RECORD_BYTES_V2 = INPUT_SIZE * sizeof(Float32) + sizeof(Float32) + sizeof(Int64) + MASK_BYTES
const RECORD_BYTES    = RECORD_BYTES_V2 + sizeof(Float32)  # v3 default
const POLICY_OFFSET   = INPUT_SIZE * sizeof(Float32) + sizeof(Float32)
const MASK_OFFSET     = POLICY_OFFSET + sizeof(Int64)
const WEIGHT_OFFSET   = MASK_OFFSET + MASK_BYTES

const NEG_INF_F32 = -1f9

mutable struct DatasetWriter
    io::IOStream
    path::String
    count::Int
end

DatasetWriter(path::AbstractString) = DatasetWriter(open(path, "w"), String(path), 0)

# Convenience overload: all moves treated as legal (for tests / synthetic data).
function write_record!(w::DatasetWriter, tensor::AbstractVector{Float32},
                       value::Float32, policy_idx::Integer,
                       sample_weight::Float32=1f0)
    mask = fill(typemax(UInt64), N_MASK_WORDS)
    write_record!(w, tensor, value, policy_idx, mask, sample_weight)
end

function write_record!(w::DatasetWriter, tensor::AbstractVector{Float32},
                       value::Float32, policy_idx::Integer,
                       legal_mask::AbstractVector{UInt64},
                       sample_weight::Float32=1f0)
    length(tensor) == INPUT_SIZE || error("tensor size $(length(tensor)) != $INPUT_SIZE")
    length(legal_mask) == N_MASK_WORDS ||
        error("legal_mask length $(length(legal_mask)) != $N_MASK_WORDS")
    write(w.io, tensor)
    write(w.io, value)
    write(w.io, Int64(policy_idx))
    write(w.io, legal_mask)
    write(w.io, clamp(sample_weight, 0f0, 1f0))
    w.count += 1
end

function close_dataset(w::DatasetWriter)
    close(w.io)
    meta = """{
  "version": 3,
  "n_records": $(w.count),
  "input_size": $INPUT_SIZE,
  "n_moves": $N_MOVES,
  "n_mask_words": $N_MASK_WORDS,
  "record_bytes": $RECORD_BYTES
}
"""
    write(w.path * ".json", meta)
end

struct DatasetReader
    data::Vector{UInt8}   # memory-mapped
    n_records::Int
    record_bytes::Int     # RECORD_BYTES_V2 or RECORD_BYTES (v3)
    has_weight::Bool      # true for v3
end

function DatasetReader(path::AbstractString)
    sidecar = path * ".json"
    version = 2
    if isfile(sidecar)
        meta = JSON3.read(read(sidecar, String))
        version = Int(get(meta, :version, 2))
        version >= 2 || error("$path: dataset version $version unsupported (need >=2). Regenerate via prepare_puzzles.")
    end
    rec_bytes = version >= 3 ? RECORD_BYTES : RECORD_BYTES_V2
    io = open(path, "r")
    filesize = stat(io).size
    filesize % rec_bytes == 0 ||
        error("$path: size $filesize not a multiple of record size $rec_bytes.")
    data = Mmap.mmap(io, Vector{UInt8}, filesize)
    close(io)
    DatasetReader(data, div(filesize, rec_bytes), rec_bytes, version >= 3)
end

function _record_tensor_view(r::DatasetReader, i::Int)
    off = (i - 1) * r.record_bytes + 1
    reinterpret(Float32, @view r.data[off : off + INPUT_SIZE * 4 - 1])
end

function _record_value(r::DatasetReader, i::Int)
    off = (i - 1) * r.record_bytes + INPUT_SIZE * 4 + 1
    reinterpret(Float32, @view r.data[off : off + 3])[1]
end

function _record_policy(r::DatasetReader, i::Int)
    off = (i - 1) * r.record_bytes + POLICY_OFFSET + 1
    reinterpret(Int64, @view r.data[off : off + 7])[1]
end

function _record_mask_view(r::DatasetReader, i::Int)
    off = (i - 1) * r.record_bytes + MASK_OFFSET + 1
    reinterpret(UInt64, @view r.data[off : off + MASK_BYTES - 1])
end

function _record_weight(r::DatasetReader, i::Int)::Float32
    r.has_weight || return 1f0
    off = (i - 1) * r.record_bytes + WEIGHT_OFFSET + 1
    reinterpret(Float32, @view r.data[off : off + 3])[1]
end

# Expand a 31-word bitmask into a length-N_MOVES Float32 column (0f0 legal, NEG_INF illegal).
function _mask_to_neginf!(col::AbstractVector{Float32}, words::AbstractVector{UInt64})
    @inbounds for k in 1:N_MOVES
        w = words[((k - 1) >> 6) + 1]
        b = (k - 1) & 63
        col[k] = ((w >> b) & UInt64(1)) == UInt64(1) ? 0f0 : NEG_INF_F32
    end
    return col
end

function make_batch(r::DatasetReader, indices::AbstractVector{Int})
    n = length(indices)
    tensors     = Matrix{Float32}(undef, INPUT_SIZE, n)
    values      = Vector{Float32}(undef, n)
    policy_idxs = Vector{Int}(undef, n)
    masks       = Matrix{Float32}(undef, N_MOVES, n)
    weights     = Vector{Float32}(undef, n)
    for (j, i) in enumerate(indices)
        tensors[:, j] .= _record_tensor_view(r, i)
        values[j]      = _record_value(r, i)
        policy_idxs[j] = _record_policy(r, i)
        _mask_to_neginf!(@view(masks[:, j]), _record_mask_view(r, i))
        weights[j]     = _record_weight(r, i)
    end
    return tensors, values, policy_idxs, masks, weights
end

function batch_iterator(r::DatasetReader, batch_size::Int; shuffle::Bool=true)
    idxs = shuffle ? Random.randperm(r.n_records) : collect(1:r.n_records)
    (make_batch(r, @view idxs[i:min(i+batch_size-1, end)]) for i in 1:batch_size:r.n_records)
end

# Draw a random mini-batch (with replacement) from a single dataset.
function random_batch(r::DatasetReader, batch_size::Int)
    idxs = rand(1:r.n_records, batch_size)
    make_batch(r, idxs)
end

# Helper: build the 31-word legal-move bitmask from a list of legal policy indices.
function build_legal_mask(legal_indices)::Vector{UInt64}
    words = zeros(UInt64, N_MASK_WORDS)
    for k in legal_indices
        (k < 1 || k > N_MOVES) && continue
        words[((k - 1) >> 6) + 1] |= UInt64(1) << ((k - 1) & 63)
    end
    return words
end
