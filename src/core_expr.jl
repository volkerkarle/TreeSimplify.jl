const ExpressionTerm = SymbolicUtils.BasicSymbolic

"""
    expression_term(x)

Convert supported inputs into a SymbolicUtils symbolic term.
"""
expression_term(x::SymbolicUtils.BasicSymbolic) = x
expression_term(x::Symbolics.Num) = Symbolics.value(x)
expression_term(x::Number) = x

"""
    stable_serialize(expr)

Serialize an expression to a deterministic plain-text representation suitable
for reproducibility artifacts and hashing.
"""
function stable_serialize(expr)
    term = expression_term(expr)
    io = IOBuffer()
    show(io, MIME("text/plain"), term)
    return String(take!(io))
end

"""
    structural_hash(expr)

Return a stable SHA1 fingerprint for a serialized expression.
"""
structural_hash(expr) = bytes2hex(sha1(stable_serialize(expr)))
