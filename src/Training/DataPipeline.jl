import Mmap

# Binary dataset format (v2)
# Each record:
#   Float32[INPUT_SIZE]  tensor
#   Float32              value
#   Int64                policy_idx
#   UInt64[N_MASK_WORDS] legal-move bitmask (bit (j*64+i) set iff policy index (j*64+i+1) is legal)
# Sidecar: <path>.json with metadata. Datasets predating the bitmask (v1) are
# rejected — regenerate via prepare_puzzles.

const N_MASK_WORDS = cld(N_MOVES, 64)             # 31 for N_MOVES=1924
const MASK_BYTES   = N_MASK_WORDS * sizeof(UInt64) # 248
const RECORD_BYTES = INPUT_SIZE * sizeof(Float32) + sizeof(Float32) + sizeof(Int64) + MASK_BYTES
const POLICY_OFFSET = INPUT_SIZE * sizeof(Float32) + sizeof(Float32)
const MASK_OFFSET   = POLICY_OFFSET + sizeof(Int64)

const NEG_INF_F32 = -1f9

mutable struct DatasetWriter
    io::IOStream
    path::String
    count::Int
end

DatasetWriter(path::AbstractString) = DatasetWriter(open(path, "w"), String(path), 0)

function write_record!(w::DatasetWriter, tensor::AbstractVector{Float32},
                       value::Float32, policy_idx::Integer,
                       legal_mask::AbstractVector{UInt64})
    length(tensor) == INPUT_SIZE || error("tensor size $(length(tensor)) != $INPUT_SIZE")
    length(legal_mask) == N_MASK_WORDS ||
        error("legal_mask length $(length(legal_mask)) != $N_MASK_WORDS")
    write(w.io, tensor)
    write(w.io, value)
    write(w.io, Int64(policy_idx))
    write(w.io, legal_mask)
    w.count += 1
end

function close_dataset(w::DatasetWriter)
    close(w.io)
    meta = """{
  "version": 2,
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
end

function DatasetReader(path::AbstractString)
    sidecar = path * ".json"
    if isfile(sidecar)
        meta = JSON3.read(read(sidecar, String))
        v = get(meta, :version, 1)
        v == 2 || error("$path: dataset version $v unsupported (need 2). Regenerate via prepare_puzzles.")
    end
    io = open(path, "r")
    filesize = stat(io).size
    filesize % RECORD_BYTES == 0 ||
        error("$path: size $filesize not a multiple of record size $RECORD_BYTES (likely v1; regenerate).")
    data = Mmap.mmap(io, Vector{UInt8}, filesize)
    close(io)
    DatasetReader(data, div(filesize, RECORD_BYTES))
end

function _record_tensor_view(r::DatasetReader, i::Int)
    off = (i - 1) * RECORD_BYTES + 1
    reinterpret(Float32, @view r.data[off : off + INPUT_SIZE * 4 - 1])
end

function _record_value(r::DatasetReader, i::Int)
    off = (i - 1) * RECORD_BYTES + INPUT_SIZE * 4 + 1
    reinterpret(Float32, @view r.data[off : off + 3])[1]
end

function _record_policy(r::DatasetReader, i::Int)
    off = (i - 1) * RECORD_BYTES + POLICY_OFFSET + 1
    reinterpret(Int64, @view r.data[off : off + 7])[1]
end

function _record_mask_view(r::DatasetReader, i::Int)
    off = (i - 1) * RECORD_BYTES + MASK_OFFSET + 1
    reinterpret(UInt64, @view r.data[off : off + MASK_BYTES - 1])
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
    for (j, i) in enumerate(indices)
        tensors[:, j] .= _record_tensor_view(r, i)
        values[j]      = _record_value(r, i)
        policy_idxs[j] = _record_policy(r, i)
        _mask_to_neginf!(@view(masks[:, j]), _record_mask_view(r, i))
    end
    return tensors, values, policy_idxs, masks
end

function batch_iterator(r::DatasetReader, batch_size::Int; shuffle::Bool=true)
    idxs = shuffle ? Random.randperm(r.n_records) : collect(1:r.n_records)
    (make_batch(r, @view idxs[i:min(i+batch_size-1, end)]) for i in 1:batch_size:r.n_records)
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
