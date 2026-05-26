# search.jl — Beam-search pipeline and expression scoring.
#
# The main entry point `simplify(expr; config=RunConfig())` orchestrates:
#   1. Beam-search expansion of rewrite candidates (depth-limited)
#   2. Targeted rational rewriting of division hotspots
#   3. Post-simplify `simplify_fractions` pass
#   4. Recursive multi-pass convergence (growing subtree budget)
#   5. Equivalence validation and trace recording

const _MAX_TREE_DEPTH = 10_000

"""
    SearchStats

Statistics collected during a single `simplify` run.

Fields:
- `expansions`       – number of candidate expressions generated
- `visited`          – number of unique expressions stored (visited set size)
- `depth_reached`    – final beam-search depth reached
- `terminated_reason`– symbol indicating why the search stopped
                       (:max_depth, :max_expansions, :max_nodes,
                        :time_budget, :frontier_exhausted,
                        :hard_case_escalation, :post_simplify)
"""
Base.@kwdef struct SearchStats
    expansions::Int = 0
    visited::Int = 0
    depth_reached::Int = 0
    terminated_reason::Symbol = :unknown
end

"""
    SimplificationResult

Complete result of a `simplify(...)` call.

Fields:
- `input_expr`        – original expression (normalised form)
- `best_expr`         – best expression found by the search
- `accepted`          – whether the result passed validation AND improved the score
- `score_before`      – cost of the input expression
- `score_after`       – cost of `best_expr`
- `validation_passed` – whether equivalence was validated
- `worst_abs_error`   – largest absolute difference (NaN if symbolic check passed)
- `worst_rel_error`   – largest relative difference (NaN if symbolic check passed)
- `stats`             – SearchStats struct
- `trace`             – TraceBuffer with the full event log
"""
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

# ---- Operator matching ----

_isop(op::Function, expr) = SymbolicUtils.iscall(expr) && SymbolicUtils.operation(expr) === op

# ---- Cost-function components ----
# Each component is a recursive tree walk bounded by _MAX_TREE_DEPTH.

"""
    _node_count(expr; _depth=0) -> Int

Total nodes in the expression tree (1 + sum of child nodes).
Leaf nodes (symbols, numbers) contribute 1.
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

Number of function-call (operator) nodes in the tree.
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

Sum of node counts of all denominators in division operators.
A key metric: rational simplification aims to reduce this.
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

Sum of positive integer exponents in the tree (e.g., `x^3` → 3).
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

Estimate common-subexpression potential by counting duplicate subtrees
(via serialised form).  Each duplicate beyond the first contributes 1.
This rewards expressions that share structure and therefore reduce
evaluation cost.
"""
function _cse_potential(expr)
    seen = Dict{String, Int}()
    _collect_subtrees!(seen, expr)
    return sum((v - 1 for v in values(seen) if v > 1); init = 0)
end

"""
    _collect_subtrees!(seen, expr; _depth=0)

Recursively serialise and count all subtrees.  Used by `_cse_potential`.
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

"""
    expression_score(expr, w::ScoringWeights) -> Float64

Weighted linear cost of an expression.  The search minimises this score.

Score = w.node_count × node_count
      + w.operation_count × operation_count
      + w.denominator_complexity × denominator_complexity
      + w.degree_profile × degree_profile
      - w.cse_potential × cse_potential   (reward for shared structure)
"""
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

# ---- Beam-search internals ----

"""
    _novelty_penalty(expr, visited) -> Int

Count how many previously visited expressions share the same 16-character
hash prefix as the given expression.  This is used as a diversity bonus
to penalise candidates that are too similar to already-explored ones.
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

Score all candidates with `expression_score` + novelty penalty, then
sort by `(score, structural_hash)` for determinism, and keep the top
`beam_width` entries.
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

"""
    _expand_candidate(expr, config; include_targeted=true) -> Tuple

Generate candidate variants of `expr` by applying rewrite-profile passes
and, if `include_targeted`, the staged rational pipeline.

Returns a tuple of (candidate_expr, family_symbol) pairs.
"""
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

"""
    _staged_rational_pipeline(expr, config) -> Expression

Multi-step rational simplification pipeline:
  1. Safe profile rewrites (clean identity/annihilator)
  2. Targeted rational rewrites (top hotspot sites)
  3. Repeat targeted rewrites at half the site count (if step 2 changed
     the expression)
  4. One final safe-rewrite pass

This staging avoids wasting budget on large unchanged subtrees.
"""
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
    simplify(expr; config=RunConfig()) -> SimplificationResult

Main entry point for TreeSimplify.  The pipeline:

**Phase 1 — Beam search** (up to `budget.max_depth` iterations):
   - Maintain a frontier of `beam_width` best candidates.
   - At each depth, expand every frontier candidate with safe rewrites,
     aggressive rewrites, and (optionally) staged rational rewrites.
   - Score each generated candidate; keep the best-scoring one.
   - Prune by `rule_family_throttle` to avoid domination by one family.
   - Stop when any budget limit (nodes, expansions, time, depth) is hit.

**Phase 2 — Hard-case escalation** (optional):
   - If the beam search produced no improvement and `enable_hard_case_escalation`
     is true, apply a strong aggressive rewrite pass.

**Phase 3 — Post-simplify**:
   - Apply `simplify_fractions` to bounded division-containing subtrees.

**Phase 4 — Multi-pass convergence**:
   - If `simplify_max_passes > 1`, recurse on the best expression with
     a larger `post_simplify_max_nodes` budget (multiplied by
     `simplify_pass_nodes_growth` per pass).

**Phase 5 — Validation**:
   - Compare best expression to input via symbolic equivalence or
     random numeric sampling.

All events are recorded in the returned `TraceBuffer`.
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

        # Stop if frontier is empty or time budget exhausted.
        if isempty(frontier)
            reason = :frontier_exhausted
            break
        end
        if (time() - start_time) >= config.budget.max_time_seconds
            reason = :time_budget
            break
        end

        # Disable targeted rational rewrites if we've had a streak of
        # unproductive depths (avoids burning budget on futile hotspot scans).
        if include_targeted && targeted_improvement_streak >= config.targeted_disable_streak
            include_targeted = false
            push_event!(trace, :targeted_disabled, payload = (depth = depth, streak = targeted_improvement_streak))
        end

        # Expand each frontier element.  Only the first few elements get
        # the (expensive) targeted rational pipeline if it's enabled.
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

                # Throttle: limit candidates per rewrite family per depth.
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

                    # Check global budget limits.
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

    # Optional hard-case escalation: if no improvement, try aggressive rewrites.
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

    # Post-simplify: apply simplify_fractions to division hotspots.
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

    # Multi-pass convergence: recurse with larger node budget.
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
            # Merge trace events from the recursive pass.
            for ev in next_result.trace.events
                push_event!(trace, ev.event, payload = ev.payload)
            end
        end
    end

    # Final validation and result construction.
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
