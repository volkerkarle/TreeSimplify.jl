const _MAX_TREE_DEPTH = 10_000

Base.@kwdef struct SearchStats
    expansions::Int = 0
    visited::Int = 0
    depth_reached::Int = 0
    terminated_reason::Symbol = :unknown
end

Base.@kwdef struct SimplificationResult
    input_expr
    best_expr
    accepted::Bool = false
    score_before::Float64 = NaN
    score_after::Float64 = NaN
    validation_passed::Bool = false
    worst_abs_error::Float64 = NaN
    worst_rel_error::Float64 = NaN
    stats::SearchStats = SearchStats()
    trace::TraceBuffer = TraceBuffer()
end

_isop(op::Function, expr) = SymbolicUtils.iscall(expr) && SymbolicUtils.operation(expr) === op

"""
    _node_count(expr; _depth=0) -> Int

Count total nodes in expression tree (1 + sum of child nodes).
Returns 1 for leaf nodes (symbols, numbers). Bounded by `_MAX_TREE_DEPTH`.
"""
function _node_count(expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return 1
    if !SymbolicUtils.iscall(expr)
        return 1
    end
    total = 1
    for arg in SymbolicUtils.arguments(expr)
        total += _node_count(arg; _depth=_depth+1)
    end
    return total
end

"""
    _operation_count(expr; _depth=0) -> Int

Count operations in expression tree (1 per call node).
Bounded by `_MAX_TREE_DEPTH`.
"""
function _operation_count(expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return 0
    if !SymbolicUtils.iscall(expr)
        return 0
    end
    total = 1
    for arg in SymbolicUtils.arguments(expr)
        total += _operation_count(arg; _depth=_depth+1)
    end
    return total
end

"""
    _denominator_complexity(expr; _depth=0) -> Int

Sum of node counts of denominators in division nodes.
Bounded by `_MAX_TREE_DEPTH`.
"""
function _denominator_complexity(expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return 0
    if !SymbolicUtils.iscall(expr)
        return 0
    end
    total = 0
    if _isop(/, expr)
        den = SymbolicUtils.arguments(expr)[2]
        total += _node_count(den)
    end
    for arg in SymbolicUtils.arguments(expr)
        total += _denominator_complexity(arg; _depth=_depth+1)
    end
    return total
end

"""
    _degree_profile(expr; _depth=0) -> Int

Sum of positive integer exponents in the expression tree.
Bounded by `_MAX_TREE_DEPTH`.
"""
function _degree_profile(expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return 0
    if !SymbolicUtils.iscall(expr)
        return 0
    end
    total = 0
    if _isop(^, expr)
        pow = SymbolicUtils.arguments(expr)[2]
        if pow isa Integer
            total += max(pow, 0)
        end
    end
    for arg in SymbolicUtils.arguments(expr)
        total += _degree_profile(arg; _depth=_depth+1)
    end
    return total
end

"""
    _cse_potential(expr) -> Int

Estimate common-subexpression reduction potential by counting duplicate subtrees.
"""
function _cse_potential(expr)
    seen = Dict{String, Int}()
    _collect_subtrees!(seen, expr)
    return sum((v - 1 for v in values(seen) if v > 1); init = 0)
end

"""
    _collect_subtrees!(seen, expr; _depth=0)

Recursively serialize and count all subtrees for `_cse_potential`.
Bounded by `_MAX_TREE_DEPTH`.
"""
function _collect_subtrees!(seen::Dict{String, Int}, expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return seen
    key = stable_serialize(expr)
    seen[key] = get(seen, key, 0) + 1
    if SymbolicUtils.iscall(expr)
        for arg in SymbolicUtils.arguments(expr)
            _collect_subtrees!(seen, arg; _depth=_depth+1)
        end
    end
    return seen
end

function expression_score(expr, w::ScoringWeights)
    node_count = _node_count(expr)
    operation_count = _operation_count(expr)
    denominator_complexity = _denominator_complexity(expr)
    degree_profile = _degree_profile(expr)
    cse_potential = _cse_potential(expr)
    return w.node_count * node_count +
           w.operation_count * operation_count +
           w.denominator_complexity * denominator_complexity +
           w.degree_profile * degree_profile -
           w.cse_potential * cse_potential
end

"""
    _novelty_penalty(expr, visited) -> Int

Count how many visited expressions share the same 16-character hash prefix,
providing a diversity penalty. Uses `structural_hash` to match `visited` key format.
"""
function _novelty_penalty(expr, visited::Dict{String, Any})
    key = structural_hash(expr)
    prefix = first(key, 16)
    similar = 0
    for existing in keys(visited)
        startswith(existing, prefix) && (similar += 1)
    end
    return similar
end

"""
    _ordered_frontier(candidates, config, visited) -> Vector

Score, sort, and select the top-k candidates by beam width.
Uses `(score, hash)` as deterministic sort key.
"""
function _ordered_frontier(candidates::Vector{Any}, config::RunConfig, visited::Dict{String, Any})
    scored = [(
        c,
        expression_score(c, config.scoring) + config.novelty_penalty * _novelty_penalty(c, visited),
        structural_hash(c),
    ) for c in candidates]
    sort!(scored, by = x -> (x[2], x[3]))
    width = min(config.budget.beam_width, length(scored))
    return [scored[i][1] for i in 1:width]
end

function _expand_candidate(expr, config::RunConfig; include_targeted::Bool = true)
    safe = apply_profile_rewrites(expr; profile = SafeRewriteProfile(), max_passes = 2)
    aggressive = apply_profile_rewrites(expr; profile = AggressiveRewriteProfile(), max_passes = 2)
    base = ((safe, :safe), (aggressive, :aggressive))
    if !include_targeted
        return base
    end
    denom = _denominator_complexity(expr)
    if denom <= 0
        return base
    end
    staged_candidate = _staged_rational_pipeline(expr, config)
    if structural_hash(staged_candidate) == structural_hash(expr)
        return base
    end
    return (base..., (staged_candidate, :staged_rational))
end

function _staged_rational_pipeline(expr, config::RunConfig)
    current = expr
    step1 = apply_profile_rewrites(current; profile = SafeRewriteProfile(), max_passes = 2)
    current = step1
    step2 = apply_targeted_rational_rewrites(
        current;
        max_sites = config.targeted_hotspot_sites,
        max_nodes = config.targeted_hotspot_max_nodes,
    )
    tidy_sites = max(1, config.targeted_hotspot_sites ÷ 2)
    if structural_hash(step2) != structural_hash(current)
        current = step2
        step3 = apply_targeted_rational_rewrites(
            current;
            max_sites = tidy_sites,
            max_nodes = config.targeted_hotspot_max_nodes,
        )
        current = step3
    end
    step4 = apply_profile_rewrites(current; profile = SafeRewriteProfile(), max_passes = 1)
    return step4
end

"""
    simplify(expr; config=RunConfig())

Entry point for TreeSimplify's search pipeline. The current scaffold is
deterministic and returns a no-op result until the beam search engine lands.
"""
function simplify(expr; config::RunConfig = RunConfig())
    symbolic_expr = expression_term(expr)
    trace = TraceBuffer()
    push_event!(trace, :run_started, payload = (seed = config.seed, beam_width = config.budget.beam_width))

    start_time = time()
    before_score = expression_score(symbolic_expr, config.scoring)
    best_expr = symbolic_expr
    best_score = before_score
    visited = Dict{String, Any}(structural_hash(symbolic_expr) => symbolic_expr)
    frontier = [symbolic_expr]
    expansions = 0
    depth_reached = 0
    reason = :max_depth
    family_counts = Dict{Symbol, Int}()
    targeted_improvement_streak = 0
    include_targeted = true

    for depth in 1:config.budget.max_depth
        depth_reached = depth
        if isempty(frontier)
            reason = :frontier_exhausted
            break
        end
        if (time() - start_time) >= config.budget.max_time_seconds
            reason = :time_budget
            break
        end

        if include_targeted && targeted_improvement_streak >= config.targeted_disable_streak
            include_targeted = false
            push_event!(trace, :targeted_disabled, payload = (depth = depth, streak = targeted_improvement_streak))
        end

        targeted_limit = min(2, length(frontier))
        expanded = [
            _expand_candidate(
                frontier[i],
                config;
                include_targeted = include_targeted && i <= targeted_limit && _denominator_complexity(frontier[i]) > 0,
            ) for i in eachindex(frontier)
        ]

        depth_improved = false
        next_candidates = Any[]
        for pair in expanded
            for candidate in pair
                cand, family = candidate
                family_count = get(family_counts, family, 0)
                if family_count >= config.rule_family_throttle
                    continue
                end
                hash = structural_hash(cand)
                if !haskey(visited, hash)
                    visited[hash] = cand
                    family_counts[family] = family_count + 1
                    push!(next_candidates, cand)
                    expansions += 1
                    score = expression_score(cand, config.scoring)
                    push_event!(trace, :candidate_generated, payload = (depth = depth, family = family, hash = hash, score = score))
                    if score < best_score
                        best_expr = cand
                        best_score = score
                        depth_improved = true
                        push_event!(trace, :best_updated, payload = (depth = depth, hash = hash, score = score))
                    end
                    if expansions >= config.budget.max_expansions || length(visited) >= config.budget.max_nodes
                        reason = expansions >= config.budget.max_expansions ? :max_expansions : :max_nodes
                        break
                    end
                end
            end
            if reason in (:max_expansions, :max_nodes)
                break
            end
        end

        if depth_improved
            targeted_improvement_streak = 0
        else
            targeted_improvement_streak += 1
        end

        if reason in (:max_expansions, :max_nodes)
            break
        end
        frontier = _ordered_frontier(next_candidates, config, visited)
        empty!(family_counts)
        push_event!(trace, :depth_completed, payload = (depth = depth, frontier = length(frontier), visited = length(visited)))
    end

    if config.enable_hard_case_escalation && best_score >= before_score
        escalated = apply_profile_rewrites(best_expr; profile = AggressiveRewriteProfile(), max_passes = 6)
        esc_score = expression_score(escalated, config.scoring)
        push_event!(trace, :hard_case_escalation, payload = (score = esc_score, hash = structural_hash(escalated)))
        if esc_score < best_score
            best_expr = escalated
            best_score = esc_score
            reason = :hard_case_escalation
        end
    end

    post_result = apply_post_simplify(
        best_expr;
        max_nodes = config.post_simplify_max_nodes,
        timeout_secs = config.post_simplify_timeout_secs,
    )
    push_event!(trace, :post_simplify,
        payload = (successful = post_result.successful, attempted = post_result.attempted,
                   elapsed = post_result.elapsed_secs, timed_out = post_result.timed_out))
    post_score = expression_score(post_result.expr, config.scoring)
    post_improved = post_score < best_score
    if post_improved
        best_expr = post_result.expr
        best_score = post_score
        reason = :post_simplify
    end

    if config.simplify_max_passes > 1 && structural_hash(best_expr) != structural_hash(symbolic_expr)
        remaining_passes = config.simplify_max_passes - 1
        next_max_nodes = round(Int, config.post_simplify_max_nodes * config.simplify_pass_nodes_growth)
        next_config = RunConfig(
            seed = config.seed,
            budget = config.budget,
            validation = config.validation,
            scoring = config.scoring,
            novelty_penalty = config.novelty_penalty,
            rule_family_throttle = config.rule_family_throttle,
            targeted_hotspot_sites = config.targeted_hotspot_sites,
            targeted_hotspot_max_nodes = config.targeted_hotspot_max_nodes,
            acceptance_improvement_min = config.acceptance_improvement_min,
            enable_hard_case_escalation = config.enable_hard_case_escalation,
            deterministic = config.deterministic,
            targeted_disable_streak = config.targeted_disable_streak,
            post_simplify_max_nodes = next_max_nodes,
            post_simplify_timeout_secs = config.post_simplify_timeout_secs,
            simplify_max_passes = remaining_passes,
            simplify_pass_nodes_growth = config.simplify_pass_nodes_growth,
        )
        next_result = simplify(best_expr; config = next_config)
        if next_result.score_after < best_score
            best_expr = next_result.best_expr
            best_score = next_result.score_after
            reason = next_result.stats.terminated_reason
            expansions += next_result.stats.expansions
            # Merge trace events from recursive pass
            for ev in next_result.trace.events
                push_event!(trace, ev.event, payload = ev.payload)
            end
        end
    end

    after_score = expression_score(best_expr, config.scoring)
    report = validate_equivalence(symbolic_expr, best_expr, config)
    improvement = before_score - after_score
    accepted = report.passed && improvement > config.acceptance_improvement_min
    push_event!(trace, :validation, payload = (passed = report.passed, mode = report.mode, worst_abs = report.worst_abs_error, worst_rel = report.worst_rel_error))
    push_event!(trace, :run_finished, payload = (reason = reason, accepted = accepted, score_before = before_score, score_after = after_score))
    stats = SearchStats(
        expansions = expansions,
        visited = length(visited),
        depth_reached = depth_reached,
        terminated_reason = reason,
    )

    return SimplificationResult(
        input_expr = symbolic_expr,
        best_expr = best_expr,
        accepted = accepted,
        score_before = before_score,
        score_after = after_score,
        validation_passed = report.passed,
        worst_abs_error = report.worst_abs_error,
        worst_rel_error = report.worst_rel_error,
        stats = stats,
        trace = trace,
    )
end
