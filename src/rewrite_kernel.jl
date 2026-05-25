abstract type AbstractRewriteProfile end

struct SafeRewriteProfile <: AbstractRewriteProfile end
struct AggressiveRewriteProfile <: AbstractRewriteProfile end

Base.@kwdef struct RegisteredRule{F}
    id::Symbol
    family::Symbol
    rewriter::F
end

"""
    rewrite_rule_registry()

Return deterministic safe and aggressive rewrite groups built on SymbolicUtils.
"""
function rewrite_rule_registry()
    safe_rules = (
        RegisteredRule(:add_zero_right, :safe_identity, @rule(~x + 0 => ~x)),
        RegisteredRule(:add_zero_left, :safe_identity, @rule(0 + ~x => ~x)),
        RegisteredRule(:sub_zero, :safe_identity, @rule(~x - 0 => ~x)),
        RegisteredRule(:mul_one_right, :safe_identity, @rule(~x * 1 => ~x)),
        RegisteredRule(:mul_one_left, :safe_identity, @rule(1 * ~x => ~x)),
        RegisteredRule(:mul_zero_right, :safe_annihilator, @rule(~x * 0 => 0)),
        RegisteredRule(:mul_zero_left, :safe_annihilator, @rule(0 * ~x => 0)),
        RegisteredRule(:div_one, :safe_identity, @rule(~x / 1 => ~x)),
        RegisteredRule(:sub_self, :safe_algebraic, @rule(~x - ~x => 0)),
        RegisteredRule(:double_add, :safe_algebraic, @rule(~x + ~x => 2 * ~x)),
    )

    aggressive_rules = (
        RegisteredRule(:self_division, :aggressive_cancel, _self_division_rule),
    )

    return (safe = safe_rules, aggressive = aggressive_rules)
end

_rk_isop(op::Function, expr) = SymbolicUtils.iscall(expr) && SymbolicUtils.operation(expr) === op

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

function _contains_division(expr; depth::Int = 0, max_depth::Int = 8)
    depth > max_depth && return false
    !_term_is_call(expr) && return false
    _rk_isop(/, expr) && return true
    for arg in SymbolicUtils.arguments(expr)
        _contains_division(arg; depth = depth + 1, max_depth = max_depth) && return true
    end
    return false
end

_term_is_call(expr) = SymbolicUtils.iscall(expr)

function _rewrite_postwalk(expr, f::Function)
    if !_term_is_call(expr)
        replacement = f(expr)
        return replacement === nothing ? expr : replacement
    end
    args = SymbolicUtils.arguments(expr)
    new_args = map(arg -> _rewrite_postwalk(arg, f), args)
    rebuilt = SymbolicUtils.operation(expr)(new_args...)
    replacement = f(rebuilt)
    return replacement === nothing ? rebuilt : replacement
end

function _simplify_rational_node(node)
    current = node
    for op in (SymbolicUtils.simplify_fractions, SymbolicUtils.quick_cancel)
        try
            updated = op(current)
            if updated !== nothing
                current = updated
            end
        catch
        end
    end
    return current
end

"""
    apply_targeted_rational_rewrites(expr; max_sites=4, max_nodes=600)

Apply heavier rational simplifications only on bounded-size hotspots
that contain division structure.
"""
function _score_hotspot(node)
    den = _denominator_complexity(node)
    n = _node_count(node)
    return den / max(n, 1)
end

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

function apply_targeted_rational_rewrites(expr; max_sites::Int = 4, max_nodes::Int = 600)
    remaining = Ref(max_sites)
    memo = Dict{UInt64, Any}()
    return _rewrite_postwalk(expr, node -> begin
        remaining[] <= 0 && return nothing
        _term_size(node; limit = max_nodes) > max_nodes && return nothing
        _contains_division(node) || return nothing
        h = hash(node)
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

_self_division_rule(expr) = _rewrite_self_division(expr)

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

function _profile_rules(profile::SafeRewriteProfile)
    return rewrite_rule_registry().safe
end

function _profile_rules(profile::AggressiveRewriteProfile)
    registry = rewrite_rule_registry()
    return (registry.safe..., registry.aggressive...)
end

"""
    apply_profile_rewrites(expr; profile=SafeRewriteProfile(), max_passes=6)

Apply deterministic rewrite passes for the selected profile.
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
        if rewritten === nothing
            break
        end
        current = rewritten
        after = structural_hash(current)
        if before == after
            break
        end
    end
    return current
end

"""
    rewrite_profiles()

Return rewrite profile identifiers used by the orchestration layer.
"""
rewrite_profiles() = (SafeRewriteProfile(), AggressiveRewriteProfile())
