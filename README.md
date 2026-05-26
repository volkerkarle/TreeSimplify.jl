# TreeSimplify.jl

**Find smaller equivalent forms of large symbolic expressions using guided search.**

Traditional `simplify()` works well on small expressions but stalls or produces
messy results on large ones (thousands of nodes, deep rational nests, repeating
subexpressions).  TreeSimplify uses **bounded beam search** over rewrite rules,
**targeted rational simplification** of division hotspots, and **multi-pass
convergence** to compact expressions that are out of reach for one-shot symbolic
simplification.

*Domain-agnostic* — no assumptions about operator algebra or physics models.

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

@variables a b c x y z

# A rational expression that traditional simplify handles poorly:
expr = ((a^2 - b^2) / (a - b)) + ((b^2 - c^2) / (b - c)) + ((c^2 - a^2) / (c - a))

result = simplify(expr)
println("Before: ", result.score_before, "  After: ", result.score_after)
println("Accepted: ", result.accepted)
println("Best expression: ", result.best_expr)
```

With defaults, TreeSimplify finds the compact form `2a + 2b + 2c`.

```julia
# Adjust the search budget for harder expressions:
config = RunConfig(
    budget = SearchBudget(max_depth = 8, beam_width = 32, max_time_seconds = 10.0),
    simplify_max_passes = 3,
)

result = simplify(very_large_expression; config = config)
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

## When is this useful?

TreeSimplify helps when:

| Situation | Example |
|---|---|
| **Large rational expressions** | Deeply nested fractions that `simplify_fractions` alone can't flatten |
| **Repeated structure** | Expressions with repeating sub-trees that CSE would capture |
| **Many equivalent forms** | When different rewrite orders produce different sizes |
| **Automated simplification** | When you want "as small as possible" without hand-guiding the simplifier |

The beam search explores diverse rewrite paths, the targeted rational pipeline
focuses on division hotspots, and the multi-pass mechanism progressively opens
larger subtrees for rewriting — all within configurable resource budgets.

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
| `run_end_to_end_validation(; config)` | Validate against expected compact forms |

---

## Configuration

```julia
# Default configuration:
config = RunConfig()

# Tight budget for quick experiments:
fast_config = RunConfig(
    budget = SearchBudget(max_depth = 4, beam_width = 16, max_time_seconds = 2.0),
)

# Aggressive simplification:
deep_config = RunConfig(
    budget = SearchBudget(max_depth = 20, beam_width = 128, max_time_seconds = 30.0),
    simplify_max_passes = 3,
    simplify_pass_nodes_growth = 2.5,
    scoring = ScoringWeights(
        denominator_complexity = 2.0,  # penalise denominators more
    ),
)
```

Key knobs:

| Field | Default | What it controls |
|---|---|---|
| `budget.max_depth` | 16 | Beam search iteration limit |
| `budget.beam_width` | 64 | Candidates retained per depth |
| `budget.max_time_seconds` | 5.0 | Wall-clock budget per `simplify` call |
| `scoring.denominator_complexity` | 1.5 | Weight for denominator size |
| `novelty_penalty` | 0.05 | Diversity bonus to avoid hash-prefix collisions |
| `simplify_max_passes` | 3 | Recursive convergence passes |
| `simplify_pass_nodes_growth` | 2.5 | Subtree size multiplier per pass |
| `post_simplify_max_nodes` | 800 | Max subtree for `simplify_fractions` |
| `targeted_hotspot_sites` | 6 | Max division hotspots rewritten per pass |

---

## Expression corpus

The `expressions/` directory contains a benchmark corpus of large rational
expressions and their expected compact forms, used for regression testing
and performance tracking.  Each expression file uses a section-delimited
format (`--- label ---` for input, `[label]` for expected output).

Add new benchmarks as separate files with provenance notes.

---

## Tests

```bash
$ julia --project -e 'using Pkg; Pkg.test()'
```

Test coverage:
- Config defaults and validation modes
- Basic simplify correctness (score improves, validation passes)
- **Determinism**: identical calls produce identical hashes and scores
- Stable serialisation: structurally equivalent expressions hash identically
- Rule registry structure and profile application
- Equivalence validation (symbolic + numeric)
- Artifact round-trip: build → save → load → replay
- Benchmark execution and end-to-end corpus validation
- Edge cases: type errors, constants, tolerances, invalid inputs

A separate determinism gate is run in CI:

```bash
$ julia --project scripts/check_determinism.jl
```

---

## Design principles

1. **Domain-agnostic** — No assumptions about operator algebra or physics
   models.  Works on any symbolic expression representable in Symbolics.jl.
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
