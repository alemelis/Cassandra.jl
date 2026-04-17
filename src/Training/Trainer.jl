struct TrainStats
    loss_value::Float32
    loss_policy::Float32
    loss_total::Float32
    n_batches::Int
end

function _policy_loss(logits::AbstractMatrix, targets::AbstractVector{Int32})
    # cross-entropy: -log(softmax(logits)[target]) for each sample
    n = length(targets)
    total = 0f0
    for i in 1:n
        col = @view logits[:, i]
        log_sum_exp = log(sum(exp.(col .- maximum(col)))) + maximum(col)
        total -= col[targets[i]] - log_sum_exp
    end
    return total / n
end

function train_epoch!(model::CassandraModel, opt_state, dataset_path::AbstractString;
                      batch_size::Int=256, value_weight::Float32=1f0,
                      policy_weight::Float32=1f0)
    reader = DatasetReader(dataset_path)
    reader.n_records == 0 && error("Empty dataset: $dataset_path")

    total_lv = 0f0; total_lp = 0f0; nb = 0

    for (tensors, values, policy_idxs) in batch_iterator(reader, batch_size)
        loss, grads = Flux.withgradient(model) do m
            value_preds, policy_logits = m(tensors)
            lv = Flux.mse(vec(value_preds), values)
            lp = _policy_loss(policy_logits, policy_idxs)
            value_weight * lv + policy_weight * lp
        end
        Flux.update!(opt_state, model, grads[1])

        # recover individual losses for logging (cheap re-forward on same batch)
        vp, pl = model(tensors)
        lv = Flux.mse(vec(vp), values)
        lp = _policy_loss(pl, policy_idxs)
        total_lv += lv; total_lp += lp; nb += 1
    end

    return TrainStats(total_lv/nb, total_lp/nb,
                      (value_weight*total_lv + policy_weight*total_lp)/nb, nb)
end
