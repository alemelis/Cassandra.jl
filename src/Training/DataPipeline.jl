# Binary dataset format
# Each record: Float32[INPUT_SIZE] tensor | Float32 value | Int32 policy_idx
# Sidecar: <path>.json with metadata

const RECORD_BYTES = INPUT_SIZE * sizeof(Float32) + sizeof(Float32) + sizeof(Int32)

struct DatasetWriter
    io::IOStream
    path::String
    count::Ref{Int}
end

function DatasetWriter(path::AbstractString)
    io = open(path, "w")
    DatasetWriter(io, path, Ref(0))
end

function write_record!(w::DatasetWriter, tensor::Vector{Float32},
                       value::Float32, policy_idx::Int32)
    write(w.io, tensor)
    write(w.io, value)
    write(w.io, policy_idx)
    w.count[] += 1
end

function close_dataset(w::DatasetWriter)
    close(w.io)
    meta = """{
  "version": 1,
  "n_records": $(w.count[]),
  "input_size": $INPUT_SIZE,
  "n_moves": $N_MOVES,
  "record_bytes": $RECORD_BYTES
}"""
    write(w.path * ".json", meta)
end

struct DatasetReader
    data::Vector{UInt8}
    n_records::Int
end

function DatasetReader(path::AbstractString)
    data = read(path)
    n = div(length(data), RECORD_BYTES)
    DatasetReader(data, n)
end

function get_record(r::DatasetReader, i::Int)
    offset = (i - 1) * RECORD_BYTES
    tensor = reinterpret(Float32, r.data[offset+1 : offset + INPUT_SIZE*4])
    voff = offset + INPUT_SIZE * 4
    value = reinterpret(Float32, r.data[voff+1 : voff+4])[1]
    poff = voff + 4
    policy_idx = reinterpret(Int32, r.data[poff+1 : poff+4])[1]
    return copy(tensor), value, policy_idx
end

function make_batch(r::DatasetReader, indices::AbstractVector{Int})
    n = length(indices)
    tensors     = Matrix{Float32}(undef, INPUT_SIZE, n)
    values      = Vector{Float32}(undef, n)
    policy_idxs = Vector{Int32}(undef, n)
    for (j, i) in enumerate(indices)
        t, v, p = get_record(r, i)
        tensors[:, j] = t
        values[j]     = v
        policy_idxs[j] = p
    end
    return tensors, values, policy_idxs
end

function batch_iterator(r::DatasetReader, batch_size::Int; shuffle::Bool=true)
    idxs = shuffle ? Random.randperm(r.n_records) : collect(1:r.n_records)
    (make_batch(r, idxs[i:min(i+batch_size-1, end)]) for i in 1:batch_size:r.n_records)
end
