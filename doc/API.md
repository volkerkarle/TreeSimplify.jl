# TreeSimplify API (draft)

## Core entry points

- `simplify(expr; config=RunConfig())`
- `run_benchmarks(; config=RunConfig())`

## Configuration

- `RunConfig`
- `SearchBudget`
- `ValidationConfig`
- `ScoringWeights`

## Rewrite pipeline

- `rewrite_rule_registry()`
- `apply_profile_rewrites(expr; profile=SafeRewriteProfile(), max_passes=6)`

## Validation

- `validate_equivalence(input_expr, candidate_expr, config)`
- `validation_modes(config)`

## Reproducibility and replay

- `stable_serialize(expr)`
- `structural_hash(expr)`
- `build_artifact(result, trace)`
- `save_artifact(path, artifact)`
- `load_artifact(path)`
- `replay_artifact(path)`
