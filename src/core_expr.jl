# core_expr.jl — common type alias, dispatch-based expression wrapping,
# deterministic serialisation, and structural hashing.
#
# ExpressionTerm is the internal symbolic representation; every external
# input (Num, BasicSymbolic, or plain Number) is normalised through
# expression_term() before entering the pipeline.

const ExpressionTerm = SymbolicUtils.BasicSymbolic

"""
    expression_term(x)

Convert any supported input type into an `ExpressionTerm`
(a `SymbolicUtils.BasicSymbolic`).  This is the single normalisation
gate that all pipeline stages must pass through.

- `BasicSymbolic` → identity
- `Num`           → unwrap via `Symbolics.value`
- `Number`        → passed through as-is (leaf nodes)
"""
expression_term(x::SymbolicUtils.BasicSymbolic) = x
expression_term(x::Symbolics.Num) = Symbolics.value(x)
expression_term(x::Number) = x

"""
    stable_serialize(expr)

Serialise an expression to a deterministic plain-text representation.

Uses Julia's `show(io, MIME("text/plain"), ...)` which produces the
same output for structurally identical trees, unlike the raw printer.
This is safe for use in reproducibility artifacts and structural hashing.
"""
function stable_serialize(expr)
    term = expression_term(expr)
    io = IOBuffer()
    show(io, MIME("text/plain"), term)
    return String(take!(io))
end

"""
    structural_hash(expr)

Return a stable SHA-1 hex digest of the expression's serialised form.

Because `stable_serialize` is deterministic, two expressions that are
structurally equivalent *always* yield the same hash, regardless of
the Julia session or platform.
"""
structural_hash(expr) = bytes2hex(sha1(stable_serialize(expr)))

# ---- Expression metrics (used by search scoring and hotspot detection) ----

const _MAX_TREE_DEPTH = 10_000

_isop(op::Function, expr) = SymbolicUtils.iscall(expr) && SymbolicUtils.operation(expr) === op

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
    _expression_metrics(expr; _depth=0) -> Tuple{Int,Int,Int,Int}

Compute (node_count, operation_count, denom_complexity, degree) in a
single tree walk, avoiding four separate traversals.  Returns a plain
tuple for zero-allocation composition.
"""
function _expression_metrics(expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return (1, 0, 0, 0)
    if !SymbolicUtils.iscall(expr)
        return (1, 0, 0, 0)
    end

    node_count = 1
    op_count = 1
    denom_complexity = 0
    degree = 0

    # Track the second child's node count for division hotspot scoring.
    div_arg2_nc = 0
    for (i, arg) in enumerate(SymbolicUtils.arguments(expr))
        nc, oc, dc, dg = _expression_metrics(arg; _depth=_depth+1)
        node_count += nc
        op_count += oc
        denom_complexity += dc
        degree += dg
        if _isop(/, expr) && i == 2
            div_arg2_nc = nc
        end
    end

    if _isop(/, expr)
        denom_complexity += div_arg2_nc
    end

    if _isop(^, expr)
        pow = SymbolicUtils.arguments(expr)[2]
        if pow isa Integer
            degree += max(pow, 0)
        end
    end

    return (node_count, op_count, denom_complexity, degree)
end

"""
    _cse_potential(expr) -> Int

Estimate common-subexpression potential by counting duplicate subtrees
(keyed by `hash(expr)` for speed, not serialised form).
Each duplicate beyond the first contributes 1.
"""
function _cse_potential(expr)
    seen = Dict{UInt64, Int}()
    _collect_subtrees!(seen, expr)
    return sum((v - 1 for v in values(seen) if v > 1); init = 0)
end

"""
    _collect_subtrees!(seen, expr; _depth=0)

Recursively count all subtrees.  Uses `hash(expr)` (fast, no string
allocation) instead of `stable_serialize`.  Bounded by `_MAX_TREE_DEPTH`.
"""
function _collect_subtrees!(seen::Dict{UInt64, Int}, expr; _depth=0)
    _depth > _MAX_TREE_DEPTH && return seen
    key = hash(expr)
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

Uses `_expression_metrics` (single-pass) for the four basic
components and `_cse_potential` (hash-keyed) for CSE.

Score = w.node_count × node_count
      + w.operation_count × operation_count
      + w.denominator_complexity × denominator_complexity
      + w.degree_profile × degree_profile
      - w.cse_potential × cse_potential   (reward for shared structure)
"""
function expression_score(expr, w::ScoringWeights)
    nc, oc, dc, dg = _expression_metrics(expr)
    cse = _cse_potential(expr)
    return w.node_count * nc + w.operation_count * oc +
           w.denominator_complexity * dc + w.degree_profile * dg -
           w.cse_potential * cse
end
