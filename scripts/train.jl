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
const DATA_PATH     = get(ENV, "DATA_PATH", get(ARGS, 2, joinpath(@__DIR__, "..", "data", "puzzles.bin")))

# Training schedule
const N_EPOCHS      = parse(Int,     get(ENV, "EPOCHS",       "20"))
const BATCH         = parse(Int,     get(ENV, "BATCH_SIZE",   "512"))
const LR            = parse(Float32, get(ENV, "LR",           "3e-4"))
const LR_MIN        = parse(Float32, get(ENV, "LR_MIN",       "3e-6"))   # cosine decay floor
const WEIGHT_DECAY  = parse(Float32, get(ENV, "WEIGHT_DECAY", "1e-4"))
const EVAL_GAMES    = parse(Int,     get(ENV, "EVAL_GAMES",   "0"))

# Loss weights
const VALUE_WEIGHT  = parse(Float32, get(ENV, "VALUE_WEIGHT",  "0.0"))
const POLICY_WEIGHT = 1f0 - VALUE_WEIGHT

# Architecture (ignored when BASE_MODEL is set)
const TRUNK_SIZES_STR = get(ENV, "TRUNK_SIZES", "256,128")
const TRUNK_SIZES     = [parse(Int, s) for s in split(TRUNK_SIZES_STR, ',') if !isempty(strip(s))]
const DROPOUT         = parse(Float32, get(ENV, "DROPOUT", "0.1"))

const BASE_MODEL    = get(ENV, "BASE_MODEL", "")

name = run_name()
println("┌─────────────────────────────────────────")
println("│  Run:          $name")
println("│  Epochs:       $N_EPOCHS  Batch: $BATCH  LR: $LR")
isempty(BASE_MODEL) || println("│  Base model:   $BASE_MODEL")
println("│  Architecture: trunk=$(join(TRUNK_SIZES, "→"))  dropout=$DROPOUT")
println("│  Loss weights: policy=$(POLICY_WEIGHT)  value=$(VALUE_WEIGHT)")
WEIGHT_DECAY > 0 && println("│  Weight decay: $WEIGHT_DECAY (AdamW)")
println("│  Data:         $DATA_PATH")
println("└─────────────────────────────────────────")

mkpath(CKPT_DIR)
mkpath(LOGS_DIR)
write(joinpath(CKPT_DIR, "run_name.txt"), name)

# ── Dataset ───────────────────────────────────────────────────────────────────

if !isfile(DATA_PATH)
    isfile(CSV_PATH) || error("CSV not found: $CSV_PATH")
    println("Building dataset from CSV…")
    n = Cassandra.prepare_puzzles(CSV_PATH, DATA_PATH)
    println("  $n records → $DATA_PATH")
else
    reader = Cassandra.DatasetReader(DATA_PATH)
    println("Dataset: $(reader.n_records) records in $DATA_PATH")
end

# ── Model ─────────────────────────────────────────────────────────────────────

model = if isempty(BASE_MODEL)
    println("Building fresh model: trunk=$(join(TRUNK_SIZES, "→"))  dropout=$DROPOUT")
    Cassandra.build_model(; trunk_sizes=TRUNK_SIZES, dropout=DROPOUT)
else
    base_path = joinpath(CKPT_DIR, BASE_MODEL * ".jld2")
    isfile(base_path) || error("Base model not found: $base_path")
    println("Loading base model: $base_path")
    m = Cassandra.load_model(base_path)
    println("  Architecture from checkpoint: trunk=$(join(m.arch.trunk_sizes, "→"))  dropout=$(m.arch.dropout)")
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
    Flux.adjust!(opt_state, cosine_lr(epoch))
    stats = Cassandra.train_epoch!(
        model, opt_state, DATA_PATH;
        batch_size    = BATCH,
        value_weight  = VALUE_WEIGHT,
        policy_weight = POLICY_WEIGHT,
        checkpoint_path = joinpath(CKPT_DIR, "latest.jld2"),
        log_path = log_path,
        epoch    = epoch,
        device   = device,
    )
    @printf("epoch %3d/%d | lr=%.2e | loss=%.4f | %d batches | %.1fs\n",
            epoch, N_EPOCHS, cosine_lr(epoch), stats.loss_policy, stats.n_batches, stats.seconds)
    flush(stdout)
end

final_path = joinpath(CKPT_DIR, "$name.jld2")
Cassandra.save_model(final_path, model |> Flux.cpu_device())
println("\nSaved: $final_path")

n_params = let ts = Vector{Int}(model.arch.trunk_sizes)
    n = Cassandra.INPUT_SIZE * ts[1] + ts[1]
    for i in 2:length(ts)
        n += ts[i-1] * ts[i] + ts[i]
    end
    lw = ts[end]; hw = max(32, lw ÷ 4)
    n += lw * hw + hw + hw * 1 + 1 + lw * Cassandra.N_MOVES + Cassandra.N_MOVES
    n
end

loss_curve = if isfile(log_path)
    entries = Any[]
    for line in readlines(log_path)
        isempty(strip(line)) && continue
        try
            e = JSON3.read(line)
            push!(entries, Dict("epoch" => e.epoch,
                                "loss_policy" => round(Float64(e.loss_policy); digits=4)))
        catch; end
    end
    entries
else
    Any[]
end

open(joinpath(CKPT_DIR, "$name.json"), "w") do io
    JSON3.write(io, (
        run_name     = name,
        completed_at = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
        epochs       = N_EPOCHS,
        batch_size   = BATCH,
        lr           = string(LR),
        trunk_sizes  = join(Vector{Int}(model.arch.trunk_sizes), ","),
        dropout      = model.arch.dropout,
        value_weight = VALUE_WEIGHT,
        weight_decay = WEIGHT_DECAY,
        base_model   = BASE_MODEL,
        dataset      = splitext(basename(DATA_PATH))[1],
        loss_policy  = round(stats.loss_policy; digits=4),
        loss_total   = round(stats.loss_total;  digits=4),
        param_count  = n_params,
        loss_curve   = loss_curve,
    ))
end

# ── Optional arena eval ───────────────────────────────────────────────────────

if EVAL_GAMES > 0
    println("\nArena: $name vs random ($EVAL_GAMES games)…")
    result = Cassandra.evaluate(model |> Flux.cpu_device(), Cassandra.build_model(), EVAL_GAMES)
    @printf("  Wins: %d  Losses: %d  Draws: %d  ELO delta: %+.0f\n",
            result.wins_a, result.wins_b, result.draws, result.elo_delta)
end
