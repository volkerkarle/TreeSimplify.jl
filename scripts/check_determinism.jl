using TreeSimplify
using Symbolics

@variables x
config = RunConfig(seed = 0x5eed)

r1 = simplify((x + x) / (x + x); config = config)
r2 = simplify((x + x) / (x + x); config = config)

if structural_hash(r1.best_expr) != structural_hash(r2.best_expr)
    error("Determinism check failed: output hash mismatch")
end

if r1.score_after != r2.score_after
    error("Determinism check failed: score mismatch")
end

println("Determinism check passed")
