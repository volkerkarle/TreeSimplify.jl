# TreeSimplify.jl

A domain-agnostic engine for simplifying large symbolic expressions using
search-based strategies.

**Status:** Working prototype — beam search baseline with BigInt rational
post-processing, multi-pass convergence, and equivalence validation.
Achieves average **1.23×** of expected compact-form scores on the SW
non-RWA corpus (9 sections, 44/44 pipeline tests passing).

---

## Installation

```julia
# Clone the repository, then:
julia> using Pkg; Pkg.add(path = "/path/to/TreeSimplify.jl")
```

Requires Julia ≥ 1.10.  Key dependencies:
- [`Symbolics.jl`](https://github.com/JuliaSymbolics/Symbolics.jl) (v6) —
  symbolic expression representation
- [`SymbolicUtils.jl`](https://github.com/JuliaSymbolics/SymbolicUtils.jl) (v3) —
  tree rewriting and rule engine

---

## Quick start

```julia
using TreeSimplify, Symbolics

@variables x y z
expr = ((x^2 - y^2) / (x - y)) + ((y^2 - z^2) / (y - z)) + ((z^2 - x^2) / (z - x))

result = simplify(expr)
println("Score: $(round(result.score_before,digits=1)) → $(round(result.score_after,digits=1))")
println("Accepted:  $(result.accepted)")
println("Best expr: $(result.best_expr)")
```

### Configuration

```julia
# Tight budget for quick experiments
fast_config = RunConfig(
    budget = SearchBudget(max_depth = 4, beam_width = 16, max_time_seconds = 2.0),
)

# Heavy multi-pass for hard rational expressions
deep_config = RunConfig(
    budget = SearchBudget(max_depth = 20, beam_width = 128, max_time_seconds = 30.0),
    simplify_max_passes = 3,
    simplify_pass_nodes_growth = 2.5,
)
```

---

## Pipeline architecture

```
Input expression
    │
    ▼
  expression_term()          — normalise to BasicSymbolic
    │
    ▼
  Beam search (depth loop)   — expand frontier with rewrite profiles
    │   ├ Safe rewrites       (identity/annihilator, always safe)
    │   ├ Aggressive rewrites (x/x→1, etc.)
    │   └ Staged rational     (targeted division-hotspot rewriting)
    │
    ▼
  Hard-case escalation       — optional aggressive pass when no improvement
    │
    ▼
  Post-simplify              — simplify_fractions on bounded subtrees
    │
    ▼
  Multi-pass convergence     — recurse with growing node budget (×2.5 per pass)
    │
    ▼
  validate_equivalence       — symbolic (fast) → numeric (fallback)
    │
    ▼
  SimplificationResult       — best_expr + score + trace + stats
```

---

## API overview

| Function / type | Description |
|---|---|
| `simplify(expr; config=RunConfig())` | Main entry point: run the full pipeline |
| `expression_term(x)` | Normalise input to `BasicSymbolic` |
| `expression_score(expr, weights)` | Weighted cost function for an expression |
| `validate_equivalence(a, b, config)` | Check if `a` and `b` are equivalent |
| `stable_serialize(expr)` | Deterministic plain-text serialisation |
| `structural_hash(expr)` | SHA-1 fingerprint of serialised form |
| `RunConfig` | Top-level configuration struct |
| `SearchBudget` | Resource limits (nodes, expansions, depth, time, beam) |
| `ScoringWeights` | Cost-function weights |
| `ValidationConfig` | Equivalence-checking parameters (tolerances, modes) |
| `SimplificationResult` | Output: best expression, scores, stats, trace |
| `rewrite_rule_registry()` | Get safe + aggressive rewrite rule groups |
| `apply_profile_rewrites(expr; profile)` | Apply a rewrite profile to an expression |
| `build_artifact(result, trace)` | Package a result for serialisation |
| `save_artifact(path, artifact)` | Write artifact to disk |
| `load_artifact(path)` | Read artifact from disk |
| `run_benchmarks(; config)` | Run all registered benchmarks |
| `run_end_to_end_validation(; config)` | Validate against expected corpus forms |

---

## Expression corpus

| File | Format | Contents |
|---|---|---|
| `expressions/sw_nonrwa_order4_coeffs.txt` | `--- label ---` sections | 9 input expressions from SW non-RWA perturbation theory |
| `expressions/extracted_sw_nonrwa_coefficients_output.txt` | `[label]` sections | Expected compact forms (reference) |

Add new benchmarks as separate files in `expressions/` with provenance notes.

---

## Tests

```bash
$ julia --project -e 'using Pkg; Pkg.test()'
```

The test suite covers:
- Config defaults and validation modes
- Basic simplify correctness (`x/x` → improved score, validated)
- **Determinism**: identical calls produce identical hashes and scores
- Stable serialisation: `x + x` and `2x` hash identically
- Rule registry structure and profile application
- Equivalence validation (symbolic + numeric)
- Artifact round-trip: build → save → load → replay
- Benchmark execution and end-to-end corpus validation (≥9 sections)
- Edge cases: type errors, constants, tolerances, invalid inputs

A separate determinism gate is run in CI:

```bash
$ julia --project scripts/check_determinism.jl
```

---

## Design principles

1. **Domain-agnostic** — No assumptions about operator algebra or physics.
2. **Deterministic** — Fixed seed, reproducible runs, structural-hash
   comparisons throughout the pipeline.
3. **Auditable** — Every `simplify()` call produces a `TraceBuffer` of
   structured events; results can be saved as `RunArtifact` for replay.
4. **Correctness-first** — Every candidate is validated before acceptance;
   no simplification is returned without an equivalence check.
5. **Resource-bounded** — Node counts, expansion counts, time, and depth
   all have hard limits configurable via `SearchBudget`.

---

## License

GNU General Public License v3.0.  See `LICENSE`.
