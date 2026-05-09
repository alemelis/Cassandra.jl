using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))

using JLD2
using JSON3

const CKPT_DIR   = get(ENV, "CHECKPOINTS_DIR", joinpath(@__DIR__, "..", "checkpoints"))
const INPUT_SIZE = 1280
const N_MOVES    = 1924

skip = Set(["latest", "deployed"])
errors = 0

for fname in readdir(CKPT_DIR)
    endswith(fname, ".jld2") || continue
    name = splitext(fname)[1]
    name in skip && continue

    jld_path  = joinpath(CKPT_DIR, fname)
    json_path = joinpath(CKPT_DIR, "$name.json")

    # Try to read embedded meta from the .jld2 first, then fall back to existing sidecar.
    embedded = try
        JLD2.jldopen(jld_path, "r") do fh
            haskey(fh, "meta") ? Dict{String,Any}(fh["meta"]) : Dict{String,Any}()
        end
    catch e
        @warn "Could not open $fname" exception=e
        global errors += 1
        continue
    end

    sidecar = if isfile(json_path)
        try JSON3.read(read(json_path, String), Dict{String,Any}) catch; Dict{String,Any}() end
    else
        Dict{String,Any}()
    end

    # Embedded meta wins; sidecar fills gaps.
    merged = merge(sidecar, embedded)

    if isempty(get(merged, "run_name", ""))
        @error "$name: no metadata found in .jld2 or sidecar JSON — " *
               "refusing to write empty card. Re-train to embed metadata."
        global errors += 1
        continue
    end

    open(json_path, "w") do io
        JSON3.write(io, merged)
    end

    rn = get(merged, "run_name", name)
    ts = get(merged, "trunk_sizes", "?")
    pc = get(merged, "param_count", "?")
    av = get(merged, "arch_version", "?")
    println("$name  run=$rn  trunk=$ts  params=$pc  arch_v=$av")
end

errors > 0 && exit(1)
println("Done.")
