# TreeSimplify.jl — main module entry point.
#
# A domain-agnostic engine for simplifying large symbolic expressions
# using bounded beam search, rewrite-rule profiles, and multi-pass
# post-processing with BigInt rational arithmetic.
#
# Architecture overview (processing order):
#   1. Parse / normalise            (expression_term)
#   2. Beam search over rewrites    (simplify in search.jl)
#   3. Targeted rational rewrite    (apply_targeted_rational_rewrites)
#   4. Post-simplify fractions      (apply_post_simplify)
#   5. Multi-pass convergence       (recursive simplify calls)
#   6. Validate equivalence         (validate_equivalence)
#   7. Trace + artifact             (TraceBuffer / RunArtifact)
#
# All public types and functions are exported below.

module TreeSimplify

using Symbolics
using SymbolicUtils
using SHA
using Statistics
using Printf

# Sub-modules for each layer of the pipeline.
include("config.jl")          # RunConfig, SearchBudget, ValidationConfig, ScoringWeights
include("core_expr.jl")       # expression_term, stable_serialize, structural_hash
include("rewrite_kernel.jl")   # Rewrite profiles, rule registry, targeted rational rewriting
include("trace.jl")            # TraceEvent, TraceBuffer, RunArtifact – audit trail
include("search.jl")           # simplify() – the main beam search entry point
include("validation.jl")       # validate_equivalence – symbolic + numeric fallback
include("benchmarks.jl")       # BenchmarkCase, EndToEndSummary, run_benchmarks, corpus loading

# ---- Configuration ----
export RunConfig
export SearchBudget
export ValidationConfig
export ScoringWeights

# ---- Search result types ----
export SimplificationResult
export SearchStats

# ---- Core pipeline ----
export simplify
export expression_term
export expression_score
export validation_modes
export ValidationReport
export validate_equivalence
export benchmark_cases
export stable_serialize
export structural_hash

# ---- Rewrite kernel ----
export RegisteredRule
export rewrite_rule_registry
export apply_profile_rewrites
export SafeRewriteProfile
export AggressiveRewriteProfile

# ---- Tracing & Artifacts ----
export TraceEvent
export TraceBuffer
export RunArtifact
export build_artifact
export save_artifact
export load_artifact
export replay_artifact

# ---- Benchmarks ----
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
