using Test
using TreeSimplify
using Symbolics

@testset "TreeSimplify" begin
    @test nameof(TreeSimplify) == :TreeSimplify

    config = RunConfig()
    @test config.deterministic
    @test config.budget.beam_width > 0
    @test validation_modes(config) == (:symbolic, :numerical)

    @variables x
    result = TreeSimplify.simplify(x / x; config = config)
    @test result.score_after <= result.score_before
    @test result.stats.expansions >= 0
    @test result.stats.visited >= 1
    @test result.stats.terminated_reason != :unknown
    @test result.validation_passed
    @test !isempty(result.trace.events)

    result2 = TreeSimplify.simplify(x / x; config = config)
    @test structural_hash(result.best_expr) == structural_hash(result2.best_expr)
    @test result.score_after == result2.score_after

    serialized = stable_serialize(x + x)
    @test !isempty(serialized)
    @test structural_hash(x + x) == structural_hash(2x)

    registry = rewrite_rule_registry()
    @test !isempty(registry.safe)
    @test !isempty(registry.aggressive)
    @test first(registry.safe) isa RegisteredRule

    safe_rewritten = apply_profile_rewrites((x + 0) * 1)
    @test isequal(safe_rewritten, x)

    aggressive_rewritten = apply_profile_rewrites((x + 1) / (x + 1); profile = AggressiveRewriteProfile())
    @test isequal(aggressive_rewritten, 1)

    report = validate_equivalence(x + x, 2x, config)
    @test report.passed

    tmp = tempname()
    artifact = build_artifact(result, result.trace)
    save_artifact(tmp, artifact)
    replay = replay_artifact(tmp)
    @test replay.input_hash == structural_hash(result.input_expr)
    @test replay.output_hash == structural_hash(result.best_expr)

    micro_config = RunConfig(
        budget = SearchBudget(max_depth = 2, beam_width = 4, max_expansions = 20, max_nodes = 100, max_time_seconds = 30.0),
        validation = ValidationConfig(symbolic_first = false, numerical_fallback = true, random_samples = 3),
    )
    bench = run_benchmarks(config = micro_config)
    @test bench.total_count == 2

    e2e_config = RunConfig(
        budget = SearchBudget(max_depth = 2, beam_width = 4, max_expansions = 20, max_nodes = 100, max_time_seconds = 30.0),
        validation = ValidationConfig(symbolic_first = false, numerical_fallback = true, random_samples = 3),
    )
    e2e = run_end_to_end_validation(config = e2e_config)
    @test e2e.total >= 9
    @test e2e.input_equivalence_passed == e2e.total
    @test e2e.output_equivalence_passed == e2e.total

    cases = benchmark_cases()
    @test length(cases) == 2
    @test occursin("expressions/", first(cases).expression_path)

    @testset "edge cases" begin
        @test_throws MethodError expression_term(nothing)
        @test_throws MethodError expression_term("string")
        @test_throws MethodError expression_term(:symbol)

        @test expression_term(42) == 42
        @test expression_term(3.14) == 3.14

        @test validate_equivalence(0, 0, config).passed
        @test validate_equivalence(1, 1, config).passed
        report = validate_equivalence(1, 2, config)
        @test !report.passed

        @test !isempty(stable_serialize(1))
        @test !isempty(stable_serialize(x))
        @test !isempty(stable_serialize(x + x))

        @test expression_score(x, config.scoring) >= 0

        @test validation_modes(config) == (:symbolic, :numerical)
        @test validation_modes(RunConfig(validation = ValidationConfig(symbolic_first = false, numerical_fallback = false))) == ()

        cfg_missing = RunConfig(validation = ValidationConfig(symbolic_first = false, numerical_fallback = true, abs_tolerance = 1e-6, rel_tolerance = 1e-6, const_tolerance = 1e-6))
        @test cfg_missing.validation.abs_tolerance == 1e-6

        @test_throws MethodError TreeSimplify.simplify("invalid")
    end
end
