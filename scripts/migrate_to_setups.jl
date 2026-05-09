#!/usr/bin/env julia
# Migrate a checkpoint-based deployment to the new setup system.
# Reads the current deployed checkpoint and bot config, writes
# setups/legacy_<name>.json and copies it to setups/deployed.json.
#
# Usage: julia --project scripts/migrate_to_setups.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Cassandra
using JSON3
using Dates

const CHECKPOINTS_DIR = get(ENV, "CHECKPOINTS_DIR", joinpath(@__DIR__, "..", "checkpoints"))
const LOGS_DIR        = get(ENV, "LOGS_DIR",        joinpath(@__DIR__, "..", "logs"))
const SETUPS_DIR      = get(ENV, "SETUPS_DIR",      joinpath(@__DIR__, "..", "setups"))

function main()
    mkpath(SETUPS_DIR)

    # Resolve deployed checkpoint name
    deployed_meta_path = joinpath(LOGS_DIR, "deployed.json")
    checkpoint_name = "deployed"
    if isfile(deployed_meta_path)
        meta = JSON3.read(read(deployed_meta_path, String), Dict{String,Any})
        checkpoint_name = get(meta, "run_name", get(meta, :run_name, "deployed"))
    end
    println("Detected deployed checkpoint: $checkpoint_name")

    # Load bot config for max_depth
    bot_config_path = joinpath(LOGS_DIR, "bot_config.json")
    max_depth = 12
    if isfile(bot_config_path)
        bc = JSON3.read(read(bot_config_path, String), Dict{String,Any})
        max_depth = get(bc, "max_depth", max_depth)
        println("Read max_depth=$max_depth from bot config")
    end

    setup_name = "legacy_$(checkpoint_name)"

    cfg = EngineConfig(
        name       = setup_name,
        created_at = Dates.format(now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS"),
        checkpoint = checkpoint_name,
        search     = SearchConfig(
            max_depth = max_depth,
            qsearch   = false,         # legacy bot used flat material eval at leaves
            null_move_enabled = false,
            lmr_enabled       = false,
            check_extension   = false,
            aspiration_window_cp = 0,
        ),
        ordering   = OrderingConfig(
            use_policy_logits = true,  # legacy bot used NN policy for ordering
            killers = false,
            history = false,
        ),
    )

    out_path     = joinpath(SETUPS_DIR, "$(setup_name).json")
    deployed_dst = joinpath(SETUPS_DIR, "deployed.json")

    save_engine_cfg(cfg, out_path)
    println("Wrote $out_path")

    save_engine_cfg(cfg, deployed_dst)
    println("Wrote $deployed_dst (active setup)")

    # Append to history log
    history_path = joinpath(SETUPS_DIR, "history.jsonl")
    open(history_path, "a") do io
        JSON3.write(io, Dict("ts" => cfg.created_at, "name" => setup_name,
                             "note" => "migrated from checkpoint deploy"))
        println(io)
    end
    println("Appended to $history_path")
    println("\nDone. Restart the bot to load the new setup.")
end

main()
