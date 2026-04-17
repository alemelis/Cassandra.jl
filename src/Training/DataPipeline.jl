import Mmap

# Binary dataset format
# Each record: Float32[INPUT_SIZE] tensor | Float32 value | Int64 policy_idx
# Sidecar: <path>.json with metadata

const RECORD_BYTES = INPUT_SIZE * sizeof(Float32) + sizeof(Float32) + sizeof(Int64)
const POLICY_OFFSET = INPUT_SIZE * sizeof(Float32) + sizeof(Float32)

mutable struct DatasetWriter
    io::IOStream
    path::String
    count::Int
end

DatasetWriter(path::AbstractString) = DatasetWriter(open(path, "w"), String(path), 0)

function write_record!(w::DatasetWriter, tensor::AbstractVector{Float32},
                       value::Float32, policy_idx::Integer)
    length(tensor) == INPUT_SIZE || error("tensor size $(length(tensor)) != $INPUT_SIZE")
    write(w.io, tensor)
    write(w.io, value)
    write(w.io, Int64(policy_idx))
    w.count += 1
end

function close_dataset(w::DatasetWriter)
    close(w.io)
    meta = """{
  "version": 1,
  "n_records": $(w.count),
  "input_size": $INPUT_SIZE,
  "n_moves": $N_MOVES,
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
    io = open(path, "r")
    filesize = stat(io).size
    filesize % RECORD_BYTES == 0 ||
        error("$path: size $filesize not a multiple of record size $RECORD_BYTES")
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

function make_batch(r::DatasetReader, indices::AbstractVector{Int})
    n = length(indices)
    tensors     = Matrix{Float32}(undef, INPUT_SIZE, n)
    values      = Vector{Float32}(undef, n)
    policy_idxs = Vector{Int}(undef, n)
    for (j, i) in enumerate(indices)
        tensors[:, j] .= _record_tensor_view(r, i)
        values[j]      = _record_value(r, i)
        policy_idxs[j] = _record_policy(r, i)
    end
    return tensors, values, policy_idxs
end

function batch_iterator(r::DatasetReader, batch_size::Int; shuffle::Bool=true)
    idxs = shuffle ? Random.randperm(r.n_records) : collect(1:r.n_records)
    (make_batch(r, @view idxs[i:min(i+batch_size-1, end)]) for i in 1:batch_size:r.n_records)
end
