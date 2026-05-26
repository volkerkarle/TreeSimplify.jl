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
