Base.@kwdef struct SearchBudget
    max_nodes::Int = 10_000
    max_expansions::Int = 25_000
    max_depth::Int = 16
    max_time_seconds::Float64 = 5.0
    beam_width::Int = 64
end

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

Base.@kwdef struct ScoringWeights
    node_count::Float64 = 1.0
    operation_count::Float64 = 0.5
    denominator_complexity::Float64 = 1.5
    degree_profile::Float64 = 0.25
    cse_potential::Float64 = 0.1
end

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
