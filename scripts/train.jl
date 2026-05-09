using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))

using Cassandra
using Dates
using Flux
using JSON3
using Printf
using Random

const ADJECTIVES = [
    "brilliant", "tactical", "aggressive", "positional", "relentless",
    "tenacious", "sharp", "enduring", "bold", "ruthless", "calm", "precise",
    "wild", "patient", "cunning", "fearless", "legendary", "electric",
    "unstoppable", "eternal", "furious", "silent", "classical", "dynamic",
    "prophylactic", "hypermodern", "zugzwang", "combinatorial", "deep",
]
const PLAYERS = [
    "kasparov", "fischer", "tal", "karpov", "anand", "carlsen", "morphy",
    "capablanca", "botvinnik", "kramnik", "spassky", "bronstein", "petrosian",
    "smyslov", "nimzowitsch", "larsen", "topalov", "polgar", "alekhine",
    "reshevsky", "geller", "kortchnoi", "euwe", "lasker", "steinitz",
]
run_name() = "$(rand(ADJECTIVES))_$(rand(PLAYERS))"

# ── Config ────────────────────────────────────────────────────────────────────

const CKPT_DIR      = get(ENV, "CHECKPOINTS_DIR", joinpath(@__DIR__, "..", "checkpoints"))
const LOGS_DIR      = get(ENV, "LOGS_DIR",        joinpath(@__DIR__, "..", "logs"))
const CSV_PATH      = get(ENV, "CSV_PATH",  get(ARGS, 1, joinpath(@__DIR__, "..", "data", "lichess_db_puzzle.csv")))
# DATA_PATH: comma-separated list of .bin dataset files (puzzles, pgn, …)
# DATA_WEIGHTS: optional comma-separated mixing weights (default = equal)
const DATA_PATH_STR    = get(ENV, "DATA_PATH", get(ARGS, 2, joinpath(@__DIR__, "..", "data", "puzzles.bin")))
const DATA_WEIGHT_STR  = get(ENV, "DATA_WEIGHTS", "")
const DATA_PATHS       = [String(strip(p)) for p in split(DATA_PATH_STR, ',') if !isempty(strip(p))]
# Keep DATA_PATH as a single path for backward-compat (first entry).
const DATA_PATH        = DATA_PATHS[1]

# Training schedule
const N_EPOCHS      = parse(Int,     get(ENV, "EPOCHS",       "20"))
const BATCH         = parse(Int,     get(ENV, "BATCH_SIZE",   "512"))
const LR            = parse(Float32, get(ENV, "LR",           "3e-4"))
const LR_MIN        = parse(Float32, get(ENV, "LR_MIN",       "3e-6"))   # cosine decay floor
const WEIGHT_DECAY  = parse(Float32, get(ENV, "WEIGHT_DECAY", "1e-4"))
const EVAL_GAMES    = parse(Int,     get(ENV, "EVAL_GAMES",   "0"))

# Loss weights
# VALUE_WEIGHT: final (post-ramp) weight on the value MSE loss.
# VALUE_WEIGHT_START: initial weight at epoch 1 (linearly ramps up to VALUE_WEIGHT
#   over VALUE_WEIGHT_RAMP_EPOCHS epochs so the random-init value head doesn't
#   swamp the policy gradient at the start of training).
const VALUE_WEIGHT             = parse(Float32, get(ENV, "VALUE_WEIGHT",             "0.5"))
const VALUE_WEIGHT_START       = parse(Float32, get(ENV, "VALUE_WEIGHT_START",       "0.1"))
const VALUE_WEIGHT_RAMP_EPOCHS = parse(Int,     get(ENV, "VALUE_WEIGHT_RAMP_EPOCHS", "5"))

function _vw(epoch::Int)::Float32
    VALUE_WEIGHT_RAMP_EPOCHS <= 1 && return VALUE_WEIGHT
    epoch >= VALUE_WEIGHT_RAMP_EPOCHS && return VALUE_WEIGHT
    VALUE_WEIGHT_START + (VALUE_WEIGHT - VALUE_WEIGHT_START) *
        Float32(epoch - 1) / Float32(VALUE_WEIGHT_RAMP_EPOCHS - 1)
end

# Architecture (ignored when BASE_MODEL is set)
# ARCH=conv (default) → conv-residual tower
# ARCH=mlp            → flat MLP (legacy, kept for ablations)
const ARCH          = get(ENV, "ARCH", "conv")
const N_CHANNELS    = parse(Int, get(ENV, "N_CHANNELS", "32"))
const N_BLOCKS      = parse(Int, get(ENV, "N_BLOCKS",   "2"))
# MLP-only knobs (ignored for conv)
const TRUNK_SIZES_STR = get(ENV, "TRUNK_SIZES", "256,128")
const TRUNK_SIZES     = [parse(Int, s) for s in split(TRUNK_SIZES_STR, ',') if !isempty(strip(s))]
const DROPOUT         = parse(Float32, get(ENV, "DROPOUT", "0.0"))

const BASE_MODEL    = get(ENV, "BASE_MODEL", "")

name = run_name()
println("┌─────────────────────────────────────────")
println("│  Run:          $name")
println("│  Epochs:       $N_EPOCHS  Batch: $BATCH  LR: $LR")
isempty(BASE_MODEL) || println("│  Base model:   $BASE_MODEL")
if ARCH == "conv"
    println("│  Architecture: conv  channels=$N_CHANNELS  blocks=$N_BLOCKS")
else
    println("│  Architecture: mlp  trunk=$(join(TRUNK_SIZES, "→"))  dropout=$DROPOUT")
end
println("│  Loss weights: value=$(VALUE_WEIGHT_START)→$(VALUE_WEIGHT) over $(VALUE_WEIGHT_RAMP_EPOCHS) epochs  policy=complement")
WEIGHT_DECAY > 0 && println("│  Weight decay: $WEIGHT_DECAY (AdamW)")
println("│  Data:         $DATA_PATH")
println("└─────────────────────────────────────────")

mkpath(CKPT_DIR)
mkpath(LOGS_DIR)
write(joinpath(CKPT_DIR, "run_name.txt"), name)

# ── Dataset ───────────────────────────────────────────────────────────────────

# Auto-build puzzle dataset if missing.
if !isfile(DATA_PATH)
    isfile(CSV_PATH) || error("CSV not found: $CSV_PATH")
    println("Building puzzle dataset from CSV…")
    n = Cassandra.prepare_puzzles(CSV_PATH, DATA_PATH)
    println("  $n records → $DATA_PATH")
end

# Verify all datasets exist and print record counts.
for p in DATA_PATHS
    isfile(p) || error("Dataset not found: $p")
    r = Cassandra.DatasetReader(p)
    println("Dataset: $(r.n_records) records in $p")
end

# Mixing weights (normalised to probabilities).
data_mixing = if isempty(DATA_WEIGHT_STR)
    fill(1.0 / length(DATA_PATHS), length(DATA_PATHS))
else
    raw = [parse(Float64, strip(s)) for s in split(DATA_WEIGHT_STR, ',')]
    length(raw) == length(DATA_PATHS) ||
        error("DATA_WEIGHTS has $(length(raw)) entries but DATA_PATH has $(length(DATA_PATHS))")
    raw ./ sum(raw)
end
println("Mixing: ", join(["$(basename(DATA_PATHS[i]))=$(round(data_mixing[i];digits=2))"
                           for i in eachindex(DATA_PATHS)], "  "))

# ── Model ─────────────────────────────────────────────────────────────────────

model = if isempty(BASE_MODEL)
    if ARCH == "conv"
        println("Building fresh conv model: channels=$N_CHANNELS  blocks=$N_BLOCKS")
        Cassandra.build_conv_model(; n_channels=N_CHANNELS, n_blocks=N_BLOCKS)
    else
        println("Building fresh MLP: trunk=$(join(TRUNK_SIZES, "→"))  dropout=$DROPOUT")
        Cassandra.build_model(; trunk_sizes=TRUNK_SIZES, dropout=DROPOUT)
    end
else
    base_path = joinpath(CKPT_DIR, BASE_MODEL * ".jld2")
    isfile(base_path) || error("Base model not found: $base_path")
    println("Loading base model: $base_path")
    m, _base_meta = Cassandra.load_model(base_path)
    av = get(m.arch, :arch_version, 0)
    if av == 2
        println("  Architecture from checkpoint: conv  channels=$(m.arch.n_channels)  blocks=$(m.arch.n_blocks)")
    else
        println("  Architecture from checkpoint: mlp  trunk=$(join(get(m.arch, :trunk_sizes, []), "→"))")
    end
    m
end

device = Flux.gpu_device()
println("│  Device:       $device")
model = model |> device

optimizer = Flux.AdamW(LR, (0.9, 0.999), WEIGHT_DECAY)
opt_state = Flux.setup(optimizer, model)

cosine_lr(ep) = LR_MIN + 0.5f0 * (LR - LR_MIN) * (1f0 + cos(Float32(π) * (ep - 1) / N_EPOCHS))
log_path  = joinpath(LOGS_DIR, "train_log.jsonl")
isfile(log_path) && rm(log_path)

print("Compiling model…")
let dummy = rand(Float32, Cassandra.INPUT_SIZE, 1) |> device
    Flux.withgradient(m -> sum(m(dummy)[2]), model)
end
println(" done.")

# ── Training ──────────────────────────────────────────────────────────────────

for epoch in 1:N_EPOCHS
    vw = _vw(epoch)
    pw = 1f0 - vw
    Flux.adjust!(opt_state, cosine_lr(epoch))

    # Dispatch: multi-dataset or single-dataset.
    stats = if length(DATA_PATHS) > 1
        Cassandra.train_epoch!(
            model, opt_state, DATA_PATHS, data_mixing;
            batch_size    = BATCH,
            value_weight  = vw,
            policy_weight = pw,
            checkpoint_path = joinpath(CKPT_DIR, "latest.jld2"),
            log_path = log_path,
            epoch    = epoch,
            device   = device,
        )
    else
        Cassandra.train_epoch!(
            model, opt_state, DATA_PATH;
            batch_size    = BATCH,
            value_weight  = vw,
            policy_weight = pw,
            checkpoint_path = joinpath(CKPT_DIR, "latest.jld2"),
            log_path = log_path,
            epoch    = epoch,
            device   = device,
        )
    end
    @printf("epoch %3d/%d | lr=%.2e | vw=%.2f | loss_v=%.4f | loss_p=%.4f | %.1fs\n",
            epoch, N_EPOCHS, cosine_lr(epoch), vw,
            stats.loss_value, stats.loss_policy, stats.seconds)
    flush(stdout)
end

final_path = joinpath(CKPT_DIR, "$name.jld2")

# Build metadata before saving so it's embedded in the .jld2 as well as the sidecar JSON.
n_params = sum(length(p) for p in Flux.trainables(model |> Flux.cpu_device()))

loss_curve = if isfile(log_path)
    entries = Any[]
    for line in readlines(log_path)
        isempty(strip(line)) && continue
        try
            e = JSON3.read(line)
            push!(entries, Dict("epoch"       => e.epoch,
                                "loss_policy" => round(Float64(e.loss_policy); digits=4),
                                "loss_value"  => round(Float64(e.loss_value);  digits=4)))
        catch; end
    end
    entries
else
    Any[]
end

arch_spec = let a = model.arch
    av = get(a, :arch_version, 0)
    if av == 2
        Dict{String,Any}("arch_version" => 2, "n_channels" => a.n_channels, "n_blocks" => a.n_blocks)
    else
        Dict{String,Any}("arch_version" => av,
                         "trunk_sizes"  => join(get(a, :trunk_sizes, []), ","),
                         "dropout"      => get(a, :dropout, 0f0))
    end
end

run_meta = merge(arch_spec, Dict{String,Any}(
    "run_name"     => name,
    "completed_at" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
    "epochs"       => N_EPOCHS,
    "batch_size"   => BATCH,
    "lr"           => string(LR),
    "value_weight" => VALUE_WEIGHT,
    "value_weight_start" => VALUE_WEIGHT_START,
    "value_weight_ramp_epochs" => VALUE_WEIGHT_RAMP_EPOCHS,
    "weight_decay" => WEIGHT_DECAY,
    "base_model"   => BASE_MODEL,
    "dataset"      => join([splitext(basename(p))[1] for p in DATA_PATHS], "+"),
    "loss_value"   => round(stats.loss_value;  digits=4),
    "loss_policy"  => round(stats.loss_policy; digits=4),
    "loss_total"   => round(stats.loss_total;  digits=4),
    "param_count"  => n_params,
    "loss_curve"   => loss_curve,
))

Cassandra.save_model(final_path, model |> Flux.cpu_device(); meta=run_meta)
println("\nSaved: $final_path")

# Write sidecar JSON (human-readable copy of what's embedded in the .jld2).
open(joinpath(CKPT_DIR, "$name.json"), "w") do io
    JSON3.write(io, run_meta)
end
println("Metadata: $(joinpath(CKPT_DIR, "$name.json"))")

# ── Optional arena eval ───────────────────────────────────────────────────────

if EVAL_GAMES > 0
    println("\nArena: $name vs random ($EVAL_GAMES games)…")
    result = Cassandra.evaluate(model |> Flux.cpu_device(), Cassandra.build_model(), EVAL_GAMES)
    @printf("  Wins: %d  Losses: %d  Draws: %d  ELO delta: %+.0f\n",
            result.wins_a, result.wins_b, result.draws, result.elo_delta)
end
