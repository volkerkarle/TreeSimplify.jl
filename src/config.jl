# config.jl — All configuration types for TreeSimplify.
#
# Every struct uses Base.@kwdef so fields can be overridden by keyword
# without repeating defaults.  The top-level RunConfig aggregates all
# sub-configs and is the only type most callers need.

"""
    SearchBudget

Resource limits for the beam-search loop.  The search stops as soon as
*any* budget limit is hit.

Fields:
- `max_nodes`       – maximum number of distinct expression nodes stored in `visited`
- `max_expansions`  – maximum rewrite-expansion steps across all depths
- `max_depth`       – maximum beam-search depth (number of rewrite iterations)
- `max_time_seconds`– wall-clock time limit per `simplify` call
- `beam_width`      – top-k candidates retained per depth level
"""
Base.@kwdef struct SearchBudget
    max_nodes::Int = 10_000
    max_expansions::Int = 25_000
    max_depth::Int = 16
    max_time_seconds::Float64 = 5.0
    beam_width::Int = 64
end

"""
    ValidationConfig

Controls how the pipeline checks that an output expression is equivalent
to the input.

Fields:
- `symbolic_first`      – try `simplify(a - b) == 0` before numeric sampling
- `numerical_fallback`  – fall back to random-point evaluation when symbolic check
                         is inconclusive or not attempted
- `random_samples`      – number of random substitution points (only used when
                          numerical_fallback is true)
- `precision_bits`      – target bit width for BigInt / BigFloat sampling
- `guard_singularities` – skip sample points where either expression is non-finite
- `abs_tolerance`       – worst allowed absolute difference
- `rel_tolerance`       – worst allowed relative difference
- `const_tolerance`     – tolerance for constant-only expressions
"""
Base.@kwdef struct ValidationConfig
    symbolic_first::Bool = true
    numerical_fallback::Bool = true
    random_samples::Int = 24
    precision_bits::Int = 256
    guard_singularities::Bool = true
    abs_tolerance::Float64 = 1e-8
    rel_tolerance::Float64 = 1e-8
    const_tolerance::Float64 = 1e-12
end

"""
    ScoringWeights

Linear weights for the expression cost function.  The cost drives both
the beam-search ordering and the acceptance criterion.  Higher weight
means the search tries harder to reduce that aspect of the expression.

Cost = Σ(w_i × metric_i)  where metrics are:
- `node_count`            – total tree-node count
- `operation_count`       – number of arithmetic operators
- `denominator_complexity`– sum of denominator-tree node counts
- `degree_profile`        – sum of non-negative integer exponents
- `cse_potential`         – *(subtracted)* duplicate-subtree count →
                             expressions with reusable sub-structures
                             are preferred, lowering the overall cost.
"""
Base.@kwdef struct ScoringWeights
    node_count::Float64 = 1.0
    operation_count::Float64 = 0.5
    denominator_complexity::Float64 = 1.5
    degree_profile::Float64 = 0.25
    cse_potential::Float64 = 0.1
end

"""
    RunConfig

Top-level configuration for a `simplify(...)` call.  Aggregates
budget, validation, and scoring configs plus pipeline-control flags.

Key pipeline knobs:
- `seed`                        – RNG seed for reproducible numerical validation
- `novelty_penalty`             – diversity bonus per hash-prefix collision in `visited`
- `rule_family_throttle`        – max candidates from the same rewrite family per depth
- `targeted_hotspot_sites`      – max division-containing subtrees rewritten per pass
- `targeted_hotspot_max_nodes`  – size bound for hotspot subtrees
- `acceptance_improvement_min`  – minimum score drop needed to accept a result
- `enable_hard_case_escalation` – when true, a final aggressive-rewrite pass fires
                                  if the beam search made no improvement
- `deterministic`               – when true, all RNG paths are seeded → reproducible runs
- `targeted_disable_streak`     – after N consecutive depth-levels without improvement,
                                  the targeted rational pipeline is temporarily disabled
- `post_simplify_max_nodes`     – max subtree size for the apply_post_simplify pass
- `post_simplify_timeout_secs`  – wall-clock limit for the post-simplify pass
- `simplify_max_passes`         – recursive multi-pass count (each pass grows the
                                  post_simplify_max_nodes budget by growth factor)
- `simplify_pass_nodes_growth`  – factor by which post_simplify_max_nodes grows per pass
"""
Base.@kwdef struct RunConfig
    seed::UInt64 = 0x5eed
    budget::SearchBudget = SearchBudget()
    validation::ValidationConfig = ValidationConfig()
    scoring::ScoringWeights = ScoringWeights()
    novelty_penalty::Float64 = 0.05
    rule_family_throttle::Int = 2
    targeted_hotspot_sites::Int = 6
    targeted_hotspot_max_nodes::Int = 800
    acceptance_improvement_min::Float64 = 1e-9
    enable_hard_case_escalation::Bool = false
    deterministic::Bool = true
    targeted_disable_streak::Int = 3
    post_simplify_max_nodes::Int = 800
    post_simplify_timeout_secs::Float64 = 60.0
    simplify_max_passes::Int = 3
    simplify_pass_nodes_growth::Float64 = 2.5
end
