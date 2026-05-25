module TreeSimplify

using Symbolics
using SymbolicUtils
using SHA
using Statistics
using Printf

include("config.jl")
include("core_expr.jl")
include("rewrite_kernel.jl")
include("trace.jl")
include("search.jl")
include("validation.jl")
include("benchmarks.jl")

export RunConfig
export SearchBudget
export ValidationConfig
export ScoringWeights
export SimplificationResult
export SearchStats
export simplify
export expression_term
export expression_score
export validation_modes
export ValidationReport
export validate_equivalence
export benchmark_cases
export stable_serialize
export structural_hash
export RegisteredRule
export rewrite_rule_registry
export apply_profile_rewrites
export SafeRewriteProfile
export AggressiveRewriteProfile
export TraceEvent
export TraceBuffer
export RunArtifact
export build_artifact
export save_artifact
export load_artifact
export replay_artifact
export run_benchmarks
export EndToEndRecord
export EndToEndSummary
export run_end_to_end_validation
export compute_quick_metrics
export run_section_benchmark
export print_section_report
export run_all_section_benchmarks
export print_benchmark_comparison

end
