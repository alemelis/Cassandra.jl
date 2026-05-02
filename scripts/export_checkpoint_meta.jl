using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))

using JLD2
using JSON3

const CKPT_DIR   = get(ENV, "CHECKPOINTS_DIR", joinpath(@__DIR__, "..", "checkpoints"))
const INPUT_SIZE = 1280
const N_MOVES    = 1924

function _param_count(trunk_sizes::Vector{Int})
    n = INPUT_SIZE * trunk_sizes[1] + trunk_sizes[1]
    for i in 2:length(trunk_sizes)
        n += trunk_sizes[i-1] * trunk_sizes[i] + trunk_sizes[i]
    end
    lw = trunk_sizes[end]
    hw = max(32, lw ÷ 4)
    n += lw * hw + hw        # value dense 1
    n += hw * 1 + 1          # value dense 2
    n += lw * N_MOVES + N_MOVES  # policy head
    return n
end

skip = Set(["latest", "deployed"])
for fname in readdir(CKPT_DIR)
    endswith(fname, ".jld2") || continue
    name = splitext(fname)[1]
    name in skip && continue

    jld_path  = joinpath(CKPT_DIR, fname)
    json_path = joinpath(CKPT_DIR, "$name.json")

    existing = Dict{String,Any}()
    if isfile(json_path)
        try
            existing = JSON3.read(read(json_path, String), Dict{String,Any})
        catch; end
    end

    trunk_sizes, dropout = try
        JLD2.jldopen(jld_path, "r") do fh
            ts = haskey(fh, "arch_trunk_sizes") ?
                     Vector{Int}(fh["arch_trunk_sizes"]) : [256, 128]
            dr = haskey(fh, "arch_dropout") ?
                     Float32(fh["arch_dropout"]) : 0f0
            (ts, dr)
        end
    catch e
        @warn "Could not read $fname" exception=e
        continue
    end

    np = _param_count(trunk_sizes)
    existing["trunk_sizes"]  = join(trunk_sizes, ",")
    existing["dropout"]      = dropout
    existing["param_count"]  = np

    open(json_path, "w") do io
        JSON3.write(io, existing)
    end
    println("$name  trunk=$(join(trunk_sizes,"→"))  params=$(np)")
end
println("Done.")
