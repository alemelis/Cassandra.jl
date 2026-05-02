using Dates: now
using Printf

struct TrainStats
    loss_value::Float32
    loss_policy::Float32
    loss_total::Float32
    n_batches::Int
    seconds::Float64
end

"""
    train_epoch!(model, opt_state, dataset_path; kwargs...) -> TrainStats

Runs one epoch. Combined loss = `value_weight*MSE + policy_weight*CE`.
Saves a checkpoint if `checkpoint_path` is given.
Appends one JSON line to `log_path` if given.
"""
function train_epoch!(model::CassandraModel, opt_state, dataset_path::AbstractString;
                      batch_size::Int=256,
                      value_weight::Float32=1f0,
                      policy_weight::Float32=1f0,
                      checkpoint_path::Union{Nothing,AbstractString}=nothing,
                      log_path::Union{Nothing,AbstractString}=nothing,
                      epoch::Int=0)
    reader = DatasetReader(dataset_path)
    reader.n_records == 0 && error("Empty dataset: $dataset_path")

    Flux.trainmode!(model)
    n_batches_total = ceil(Int, reader.n_records / batch_size)
    total_lv = 0f0; total_lp = 0f0; nb = 0
    t0 = time()

    for (tensors, values, policy_idxs) in batch_iterator(reader, batch_size; shuffle=false)
        targets = Flux.onehotbatch(policy_idxs, 1:N_MOVES)

        (total, (lv, lp)), grads = Flux.withgradient(model) do m
            value_preds, policy_logits = m(tensors)
            lv_ = Flux.mse(vec(value_preds), values)
            lp_ = Flux.logitcrossentropy(policy_logits, targets)
            value_weight * lv_ + policy_weight * lp_, (lv_, lp_)
        end
        Flux.update!(opt_state, model, grads[1])

        total_lv += lv; total_lp += lp; nb += 1

        if nb % 200 == 0
            elapsed = time() - t0
            eta = elapsed / nb * (n_batches_total - nb)
            @printf("\r  [%d/%d]  loss=%.4f  elapsed=%.0fs  eta=%.0fs    ",
                    nb, n_batches_total, total_lp / nb, elapsed, eta)
            flush(stdout)
        end
    end
    nb > 0 && print("\r" * " "^80 * "\r")
    Flux.testmode!(model)

    stats = TrainStats(total_lv/nb, total_lp/nb,
                       (value_weight*total_lv + policy_weight*total_lp)/nb,
                       nb, time() - t0)

    checkpoint_path === nothing || save_model(checkpoint_path, model)

    if log_path !== nothing
        entry = (ts=string(now()), epoch=epoch, n_batches=stats.n_batches,
                 seconds=round(stats.seconds; digits=3),
                 loss_value=stats.loss_value, loss_policy=stats.loss_policy,
                 loss_total=stats.loss_total, batch_size=batch_size,
                 n_records=reader.n_records)
        open(log_path, "a") do io
            JSON3.write(io, entry)
            println(io)
        end
    end

    return stats
end
