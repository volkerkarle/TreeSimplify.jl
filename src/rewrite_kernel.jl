# rewrite_kernel.jl — Rewrite-rule definitions, profiles, and the
# targeted rational-simplification pipeline.
#
# This file owns:
#   - The `AbstractRewriteProfile` hierarchy (safe / aggressive)
#   - The deterministic rule registry built on SymbolicUtils `@rule`
#   - Bounded rewrite engines: `apply_profile_rewrites`,
#     `apply_targeted_rational_rewrites`, `apply_post_simplify`
#
# All rule applications are bounded by node-count limits to prevent
# explosion on large expressions.

abstract type AbstractRewriteProfile end

# SafeRewriteProfile — identity/annihilator rules only (always
#                          structure-preserving).
# AggressiveRewriteProfile — includes safe rules plus cancellations
#                              such as x/x → 1.
struct SafeRewriteProfile <: AbstractRewriteProfile end
struct AggressiveRewriteProfile <: AbstractRewriteProfile end

"""
    RegisteredRule{F}

A named rule paired with a `family` tag for throttling and audit.

Fields:
- `id`       — unique Symbol identifier
- `family`   – grouping key (`:safe_identity`, `:safe_annihilator`,
               `:safe_algebraic`, `:aggressive_cancel`); limiters in
               the search engine use this to cap candidates per family.
- `rewriter` – callable that takes an expression and returns either a
               rewritten expression or `nothing` (no match).
"""
Base.@kwdef struct RegisteredRule{F}
    id::Symbol
    family::Symbol
    rewriter::F
end

# ---- Self-division rule (must precede rewrite_rule_registry for const init) ----

_self_division_rule(expr) = _rewrite_self_division(expr)

"""
    _rewrite_self_division(expr)

Check whether `expr` is a division `x / x`.  If so, return the literal
`1`.  This handles the symbolic case where SymbolicUtils' `@rule` may
not match due to the lack of a `~x` pattern binder tolerance.
"""
function _rewrite_self_division(expr)
    if !SymbolicUtils.iscall(expr)
        return nothing
    end
    op = SymbolicUtils.operation(expr)
    if op != /
        return nothing
    end
    args = SymbolicUtils.arguments(expr)
    if length(args) != 2
        return nothing
    end
    num, den = args
    if den isa Number && iszero(den)
        return nothing
    end
    if isequal(num, den)
        return 1
    end
    return nothing
end

"""
    rewrite_rule_registry()

Return a NamedTuple `(safe = ..., aggressive = ...)` containing
deterministic rewrite rules built on SymbolicUtils `@rule` macro.

Safe rules: add_zero_right, add_zero_left, sub_zero, mul_one_right,
mul_one_left, pow_one, one_pow, mul_zero_right, mul_zero_left,
div_one, sub_self, double_add, double_neg, common_denom_add,
common_denom_sub.

Aggressive rules: self_division, negate_sum.
"""
function rewrite_rule_registry()
    safe_rules = (
        RegisteredRule(:add_zero_right, :safe_identity, @rule(~x + 0 => ~x)),
        RegisteredRule(:add_zero_left,  :safe_identity, @rule(0 + ~x => ~x)),
        RegisteredRule(:sub_zero,       :safe_identity, @rule(~x - 0 => ~x)),
        RegisteredRule(:mul_one_right,  :safe_identity, @rule(~x * 1 => ~x)),
        RegisteredRule(:mul_one_left,   :safe_identity, @rule(1 * ~x => ~x)),
        RegisteredRule(:pow_one,        :safe_identity, @rule((~x)^1 => ~x)),
        RegisteredRule(:one_pow,        :safe_identity, @rule(1^~x => 1)),
        RegisteredRule(:mul_zero_right, :safe_annihilator, @rule(~x * 0 => 0)),
        RegisteredRule(:mul_zero_left,  :safe_annihilator, @rule(0 * ~x => 0)),
        RegisteredRule(:div_one,        :safe_identity, @rule(~x / 1 => ~x)),
        RegisteredRule(:sub_self,       :safe_algebraic, @rule(~x - ~x => 0)),
        RegisteredRule(:double_add,     :safe_algebraic, @rule(~x + ~x => 2 * ~x)),
        RegisteredRule(:double_neg,     :safe_algebraic, @rule(-(-~x) => ~x)),
        RegisteredRule(:common_denom_add,  :safe_algebraic, @rule(~a / ~b + ~c / ~b => (~a + ~c) / ~b)),
        RegisteredRule(:common_denom_sub,  :safe_algebraic, @rule(~a / ~b - ~c / ~b => (~a - ~c) / ~b)),
    )

    aggressive_rules = (
        RegisteredRule(:self_division, :aggressive_cancel, _self_division_rule),
        RegisteredRule(:negate_sum,    :aggressive_cancel, @rule(-(~a + ~b) => -(~a) - (~b))),
    )

    return (safe = safe_rules, aggressive = aggressive_rules)
end

const _RULE_REGISTRY = rewrite_rule_registry()

# ---- Internal helpers ----

# Check whether `expr` is a call to the given function `op`.

"""
    _term_size(expr; limit=10_000)

Count total nodes in an expression tree using an iterative stack.
Returns `limit + 1` as a sentinel if the limit is exceeded, avoiding
deep recursion on huge trees.
"""
function _term_size(expr; limit::Int = 10_000)
    total = 0
    stack = Any[expr]
    while !isempty(stack)
        node = pop!(stack)
        total += 1
        total > limit && return limit + 1
        if SymbolicUtils.iscall(node)
            append!(stack, SymbolicUtils.arguments(node))
        end
    end
    return total
end

# Recursive check (bounded by `max_depth`) for division nodes.
function _contains_division(expr; depth::Int = 0, max_depth::Int = 8)
    depth > max_depth && return false
    !_term_is_call(expr) && return false
    _isop(/, expr) && return true
    for arg in SymbolicUtils.arguments(expr)
        _contains_division(arg; depth = depth + 1, max_depth = max_depth) && return true
    end
    return false
end

_term_is_call(expr) = SymbolicUtils.iscall(expr)

"""
    _rewrite_postwalk(expr, f)

Bottom-up (post-order) tree walk using an explicit stack.
`f` is called on every node after its children have been visited.
Returns `f`'s return value if non-nothing, otherwise the (possibly
rebuilt) node unchanged.  Iterative — safe for arbitrarily deep trees.
"""
function _rewrite_postwalk(expr, f::Function)
    # Explicit stack of (node, state) pairs.
    # Uses `Any` for the node slot because `arguments(...)` may return
    # arithmetic leaf types (e.g. Rational{BigInt}) alongside BasicSymbolic.
    stack = Vector{Tuple{Any, Symbol}}()
    push!(stack, (expr, :enter))
    rebuilt = IdDict()

    while !isempty(stack)
        node, state = pop!(stack)

        if !_term_is_call(node)
            r = f(node)
            rebuilt[node] = r === nothing ? node : r
            continue
        end

        if state === :enter
            push!(stack, (node, :exit))
            for arg in reverse(SymbolicUtils.arguments(node))
                push!(stack, (arg, :enter))
            end
        else
            new_args = Any[rebuilt[arg] for arg in SymbolicUtils.arguments(node)]
            r_expr = SymbolicUtils.operation(node)(new_args...)
            r = f(r_expr)
            rebuilt[node] = r === nothing ? r_expr : r
        end
    end

    return rebuilt[expr]
end

"""
    _count_divisions(expr; depth=0, max_depth=20)

Count the number of division operators in an expression tree, bounded
by `max_depth`.  Used to avoid expensive multivariate GCD in
`simplify_fractions` when there are many unrelated divisions.
"""
function _count_divisions(expr; depth::Int = 0, max_depth::Int = 20)
    depth > max_depth && return 0
    !_term_is_call(expr) && return 0
    total = _isop(/, expr) ? 1 : 0
    for arg in SymbolicUtils.arguments(expr)
        total += _count_divisions(arg; depth = depth + 1, max_depth = max_depth)
    end
    return total
end

"""
    _simplify_rational_node(node; max_divisions=3)

Apply `simplify_fractions` and `quick_cancel` in sequence to a single
tree node.  `simplify_fractions` is skipped when the subtree contains
more than `max_divisions` division nodes, because its multivariate-GCD
step scales exponentially with the number of independent fraction terms.
"""
function _simplify_rational_node(node; max_divisions::Int = 3)
    current = node
    n_div = _count_divisions(current)
    ops = n_div <= max_divisions ?
        (SymbolicUtils.simplify_fractions, SymbolicUtils.quick_cancel) :
        (SymbolicUtils.quick_cancel,)
    for op in ops
        try
            updated = op(current)
            if updated !== nothing
                current = updated
            end
        catch e
            e isa InterruptException && rethrow()
            @debug "simplify_fractions/quick_cancel failed" node = structural_hash(node) exception = e
        end
    end
    return current
end

# ---- Hotspot detection / targeted rewriting ----

"""
    _score_hotspot(node)

Score a division-containing subtree by `denominator_complexity / node_count`.
Higher scores mean the denominator is relatively complex, making the
subtree a promising target for rational simplification.
"""
function _score_hotspot(node)
    den = _denominator_complexity(node)
    n = _node_count(node)
    return den / max(n, 1)
end

"""
    _collect_hotspots(expr; max_nodes=600)

Walk the expression tree and collect all division-containing subtrees
whose size is ≤ `max_nodes`, sorted by hotspot score descending.
Only the top sites are later rewritten (see `apply_targeted_rational_rewrites`).
"""
function _collect_hotspots(expr; max_nodes::Int = 600)
    hotspots = Tuple{Float64, Any}[]
    _rewrite_postwalk(expr, node -> begin
        if _contains_division(node) && _term_size(node; limit = max_nodes) <= max_nodes
            score = _score_hotspot(node)
            push!(hotspots, (score, node))
        end
        return nothing
    end)
    sort!(hotspots, by = x -> x[1], rev = true)
    return hotspots
end

"""
    apply_targeted_rational_rewrites(expr; max_sites=4, max_nodes=600)

Apply `simplify_fractions` / `quick_cancel` to the highest-scored
division hotspots in the expression tree, bounded by `max_sites`
rewrites and `max_nodes` per subtree.  Results are memoised by hash
to avoid redundant work.

This is the main mechanism that handles large rational expressions
without rewriting the entire tree.
"""
function apply_targeted_rational_rewrites(expr; max_sites::Int = 4, max_nodes::Int = 600)
    remaining = Ref(max_sites)
    memo = Dict{String, Any}()
    return _rewrite_postwalk(expr, node -> begin
        remaining[] <= 0 && return nothing
        _term_size(node; limit = max_nodes) > max_nodes && return nothing
        _contains_division(node) || return nothing
        h = structural_hash(node)
        if haskey(memo, h)
            cached = memo[h]
            if cached !== nothing && structural_hash(cached) != structural_hash(node)
                remaining[] -= 1
                return cached
            end
            return nothing
        end
        candidate = _simplify_rational_node(node)
        if structural_hash(candidate) != structural_hash(node)
            remaining[] -= 1
            memo[h] = candidate
            return candidate
        end
        memo[h] = nothing
        return nothing
    end)
end

# ---- Profile dispatch ----

_profile_rules(::SafeRewriteProfile)      = _RULE_REGISTRY.safe
_profile_rules(::AggressiveRewriteProfile) = (_RULE_REGISTRY.safe..., _RULE_REGISTRY.aggressive...)

"""
    apply_profile_rewrites(expr; profile=SafeRewriteProfile(), max_passes=6)

Apply the rewrite rules of the selected profile in a pre-walk (top-down)
chain, repeating up to `max_passes` times.  Early termination when a
pass produces no change.

This is the main entry point for lightweight, bounded symbolic
simplification by tree rewriting.
"""
function apply_profile_rewrites(expr; profile::AbstractRewriteProfile = SafeRewriteProfile(), max_passes::Int = 6)
    current = expression_term(expr)
    rules = _profile_rules(profile)
    if isempty(rules)
        return current
    end
    pipeline = SymbolicUtils.Rewriters.Prewalk(SymbolicUtils.Rewriters.Chain(map(r -> r.rewriter, rules)))
    for _ in 1:max_passes
        before = structural_hash(current)
        rewritten = pipeline(current)
        current = rewritten
        after = structural_hash(current)
        if before == after
            break
        end
    end
    return current
end

"""
    apply_post_simplify(expr; max_nodes=800, max_passes=4, timeout_secs=60.0)

After the main beam search, apply `simplify_fractions` to
division-containing subtrees bounded by `max_nodes`.  This pass uses
BigInt-coefficient-safe arithmetic provided by SymbolicUtils.

Returns a NamedTuple:
    (expr, successful, attempted, elapsed_secs, timed_out)
"""
function apply_post_simplify(expr; max_nodes::Int = 800, max_passes::Int = 4, timeout_secs::Float64 = 60.0)
    current = expression_term(expr)
    start_time = time()
    successful = 0
    attempted = Ref(0)
    for pass in 1:max_passes
        this_pass = Ref(0)
        rewritten = _rewrite_postwalk(current, node -> begin
            if (time() - start_time) >= timeout_secs
                return nothing
            end
            attempted[] += 1
            if _term_size(node; limit = max_nodes) > max_nodes
                return nothing
            end
            _contains_division(node) || return nothing
            candidate = _simplify_rational_node(node)
            if candidate === nothing || structural_hash(candidate) == structural_hash(node)
                return nothing
            end
            this_pass[] += 1
            return candidate
        end)
        successful += this_pass[]
        before_hash = structural_hash(current)
        current = rewritten
        if (time() - start_time) >= timeout_secs
            break
        end
        if structural_hash(current) == before_hash
            break
        end
    end
    elapsed = time() - start_time
    return (
        expr = current,
        successful = successful,
        attempted = attempted[],
        elapsed_secs = elapsed,
        timed_out = elapsed >= timeout_secs,
    )
end

"""
    rewrite_profiles()

Return a tuple of (SafeRewriteProfile(), AggressiveRewriteProfile())
for use by the orchestration layer in the search pipeline.
"""
rewrite_profiles() = (SafeRewriteProfile(), AggressiveRewriteProfile())
