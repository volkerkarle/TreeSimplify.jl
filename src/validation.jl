# validation.jl — Equivalence checking for simplification results.
#
# Two validation modes are supported:
#   1. Symbolic: compute `simplify(a - b) == 0`.
#   2. Numeric: evaluate at random substitution points with
#      configurable tolerance.
#
# The symbolic check is tried first (when `symbolic_first` is true).
# The numeric fallback runs when the symbolic check fails or is
# disabled.  If both are disabled, no validation is performed.

using Random

"""
    ValidationReport

Result of a single equivalence check.

Fields:
- `passed`             – whether the expressions are considered equivalent
- `mode`               – the mode that produced the result (`:symbolic`,
                         `:numerical`, or `:none`)
- `worst_abs_error`    – largest absolute difference detected
- `worst_rel_error`    – largest relative difference detected
- `samples_evaluated`  – number of sample points used (1 for symbolic,
                         0 for :none)
"""
Base.@kwdef struct ValidationReport
    passed::Bool = false
    mode::Symbol = :none
    worst_abs_error::Float64 = Inf
    worst_rel_error::Float64 = Inf
    samples_evaluated::Int = 0
end

"""
    validation_modes(config)

Return a tuple of enabled validation mode symbols in deterministic
order: `(:symbolic,)`, `(:numerical,)`, `(:symbolic, :numerical)`, or `()`.
"""
function validation_modes(config::RunConfig)
    modes = Symbol[]
    config.validation.symbolic_first && push!(modes, :symbolic)
    config.validation.numerical_fallback && push!(modes, :numerical)
    return Tuple(modes)
end

"""
    validate_equivalence(input_expr, candidate_expr, config) -> ValidationReport

Check whether `input_expr` and `candidate_expr` are mathematically
equivalent.  Uses the mode order specified by `validation_modes`.
"""
function validate_equivalence(input_expr, candidate_expr, config::RunConfig)
    if config.validation.symbolic_first && _symbolic_equivalent(input_expr, candidate_expr)
        return ValidationReport(passed = true, mode = :symbolic, worst_abs_error = 0.0, worst_rel_error = 0.0)
    end
    if config.validation.numerical_fallback
        return _numeric_validation(input_expr, candidate_expr, config)
    end
    return ValidationReport()
end

"""
    _symbolic_equivalent(a, b) -> Bool

Symbolic equivalence check: `simplify(a - b) == 0`.
Fast and exact when Symbolics can reduce the difference to zero.
May be inconclusive (return false) for large or non-polynomial
expressions.
"""
function _symbolic_equivalent(a, b)
    diff_expr = Symbolics.simplify(a - b)
    return diff_expr == 0
end

"""
    _numeric_validation(a, b, config) -> ValidationReport

Numeric equivalence check via random sampling.

- For constant expressions: evaluate `a - b` directly and compare
  to `const_tolerance`.
- For symbolic expressions: sample `random_samples` points from
  [-1, 1] for each variable; skip points where either expression
  is non-finite (singularity guard).  Use seeded RNG for reproducibility.
"""
function _numeric_validation(a, b, config::RunConfig)
    vc = config.validation
    vars = Symbolics.get_variables(a - b)

    # Constant-only case: evaluate directly.
    if isempty(vars)
        try
            d = a - b
            value = d isa Number ? float(d) : float(Symbolics.value(d))
            ok = abs(value) <= vc.const_tolerance
            return ValidationReport(
                passed = ok,
                mode = :numerical,
                worst_abs_error = abs(value),
                worst_rel_error = abs(value),
                samples_evaluated = 1,
            )
        catch e
            @debug "Constant validation failed" exception = e
            return ValidationReport()
        end
    end

    # Variable-dependent case: random sampling.
    rng = Random.MersenneTwister(config.seed)
    worst_abs = 0.0
    worst_rel = 0.0
    valid = 0
    for _ in 1:vc.random_samples
        assign = Dict(v => rand(rng) * 2 - 1 for v in vars)
        av = Symbolics.substitute(a, assign)
        bv = Symbolics.substitute(b, assign)
        try
            af = float(Symbolics.value(av))
            bf = float(Symbolics.value(bv))
            if !isfinite(af) || !isfinite(bf)
                continue
            end
            err = abs(af - bf)
            denom = max(abs(af), abs(bf))
            rel = if denom > 0
                err / denom
            elseif err == 0
                0.0
            else
                Inf
            end
            worst_abs = max(worst_abs, err)
            worst_rel = max(worst_rel, rel)
            valid += 1
        catch e
            @debug "Numerical validation sample failed" exception = e
        end
    end

    pass = valid > 0 && worst_abs <= vc.abs_tolerance && worst_rel <= vc.rel_tolerance
    return ValidationReport(
        passed = pass,
        mode = :numerical,
        worst_abs_error = worst_abs,
        worst_rel_error = worst_rel,
        samples_evaluated = valid,
    )
end
