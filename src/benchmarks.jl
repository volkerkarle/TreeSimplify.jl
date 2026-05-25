Base.@kwdef struct BenchmarkCase
    name::String
    expression_path::String
end

Base.@kwdef struct BenchmarkResult
    case::BenchmarkCase
    parsed::Bool
    accepted::Bool
    score_before::Float64
    score_after::Float64
    output_hash::String
    terminated_reason::Symbol
end

Base.@kwdef struct BenchmarkSummary
    results::Vector{BenchmarkResult}
    accepted_count::Int
    total_count::Int
    median_improvement::Float64
end

Base.@kwdef struct EndToEndRecord
    label::String
    input_equivalent_to_expected::Bool
    output_equivalent_to_expected::Bool
    accepted::Bool
    score_before::Float64
    score_after::Float64
end

Base.@kwdef struct EndToEndSummary
    records::Vector{EndToEndRecord}
    total::Int
    input_equivalence_passed::Int
    output_equivalence_passed::Int
end

"""
    benchmark_cases()

Return the initial benchmark corpus paths.
"""
function benchmark_cases()
    root = normpath(joinpath(@__DIR__, ".."))
    return (
        BenchmarkCase("sw_nonrwa_order4_coeffs", joinpath(root, "expressions/sw_nonrwa_order4_coeffs.txt")),
        BenchmarkCase("extracted_sw_nonrwa_coefficients_output", joinpath(root, "expressions/extracted_sw_nonrwa_coefficients_output.txt")),
    )
end

function _normalize_expected_label(label::AbstractString)
    compact = replace(strip(label), " " => "")
    mapping = Dict(
        "1" => "identity",
        "a'a" => "a†a",
        "a'²" => "a†²",
        "a²" => "a²",
        "a'⁴" => "a†⁴",
        "a⁴" => "a⁴",
        "a'³a" => "a†³a",
        "a'a³" => "a†a³",
        "a'²a²" => "a†²a²",
    )
    return get(mapping, compact, compact)
end

function _parse_symbolic_expression(raw::AbstractString; python_syntax::Bool)
    expr_str = strip(raw)
    python_syntax && (expr_str = replace(expr_str, "**" => "^"))
    python_syntax && (expr_str = replace(expr_str, r"\bw\b" => "ω"))
    expr_str = replace(expr_str, r"(\d+)//(\d+)" => s"BigInt(\1)//BigInt(\2)")
    parsed = Meta.parse(expr_str)
    g1, g2, d1, d3, ω = let
        @variables g1 g2 d1 d3 ω
        (g1, g2, d1, d3, ω)
    end
    let_expr = quote
        let g1 = $g1, g2 = $g2, d1 = $d1, d3 = $d3, ω = $ω
            $parsed
        end
    end
    return Core.eval(@__MODULE__, let_expr)
end

function _load_sw_sections(path::String)
    sections = Dict{String, Any}()
    current = ""
    for line in eachline(path)
        s = strip(line)
        m = match(r"^---\s+(.*)\s+---$", s)
        if m !== nothing
            current = strip(m.captures[1])
            continue
        end
        if isempty(s) || startswith(s, "#") || isempty(current)
            continue
        end
        sections[current] = _parse_symbolic_expression(s; python_syntax = false)
    end
    return sections
end

function _load_expected_sections(path::String)
    sections = Dict{String, Any}()
    lines = readlines(path)
    i = 1
    while i <= length(lines)
        s = strip(lines[i])
        m = match(r"^\[(.*)\]$", s)
        if m !== nothing
            label = _normalize_expected_label(m.captures[1])
            i += 1
            while i <= length(lines) && isempty(strip(lines[i]))
                i += 1
            end
            if i <= length(lines)
                expr_line = strip(lines[i])
                if !startswith(expr_line, "check ")
                    sections[label] = _parse_symbolic_expression(expr_line; python_syntax = true)
                end
            end
        end
        i += 1
    end
    return sections
end

function run_end_to_end_validation(
    sw_path::String = joinpath(normpath(joinpath(@__DIR__, "..")), "expressions/sw_nonrwa_order4_coeffs.txt"),
    expected_path::String = joinpath(normpath(joinpath(@__DIR__, "..")), "expressions/extracted_sw_nonrwa_coefficients_output.txt");
    config::RunConfig = RunConfig(),
)
    sw = _load_sw_sections(sw_path)
    expected = _load_expected_sections(expected_path)
    labels = sort(collect(intersect(keys(sw), keys(expected))))
    records = EndToEndRecord[]
    for label in labels
        input_expr = sw[label]
        expected_expr = expected[label]
        input_report = validate_equivalence(input_expr, expected_expr, config)
        result = simplify(input_expr; config = config)
        output_report = validate_equivalence(result.best_expr, expected_expr, config)
        push!(records, EndToEndRecord(
            label = label,
            input_equivalent_to_expected = input_report.passed,
            output_equivalent_to_expected = output_report.passed,
            accepted = result.accepted,
            score_before = result.score_before,
            score_after = result.score_after,
        ))
    end
    return EndToEndSummary(
        records = records,
        total = length(records),
        input_equivalence_passed = count(r -> r.input_equivalent_to_expected, records),
        output_equivalence_passed = count(r -> r.output_equivalent_to_expected, records),
    )
end

function _detect_file_format(path::String)
    section_line = ""
    for line in eachline(path)
        s = strip(line)
        isempty(s) && continue
        startswith(s, "#") && continue
        if startswith(s, "---") || startswith(s, "[")
            section_line = s
            break
        end
    end
    if !isempty(section_line)
        return startswith(section_line, "---") ? :sw_sections : :expected_sections
    end
    return :plain
end

function _load_case_expression(case::BenchmarkCase)
    if !isfile(case.expression_path)
        return nothing
    end
    fmt = _detect_file_format(case.expression_path)
    if fmt === :sw_sections
        sections = _load_sw_sections(case.expression_path)
        labels = collect(keys(sections))
        isempty(labels) && return nothing
        sort!(labels)
        return sections[first(labels)]
    elseif fmt === :expected_sections
        sections = _load_expected_sections(case.expression_path)
        labels = collect(keys(sections))
        isempty(labels) && return nothing
        sort!(labels)
        return sections[first(labels)]
    else
        raw = read(case.expression_path, String)
        s = strip(raw)
        isempty(s) && return nothing
        return _parse_symbolic_expression(s; python_syntax = false)
    end
end

"""
    compute_quick_metrics(expr)

Return a NamedTuple of lightweight metrics: node_count, operation_count,
serialized_len, denominator_complexity, degree_profile, cse_potential.
"""
function compute_quick_metrics(expr)
    t = expression_term(expr)
    return (
        node_count = _node_count(t),
        operation_count = _operation_count(t),
        serialized_len = length(stable_serialize(t)),
        denominator_complexity = _denominator_complexity(t),
        degree_profile = _degree_profile(t),
        cse_potential = _cse_potential(t),
    )
end

"""
    run_section_benchmark(label, input_expr; config=RunConfig())

Run simplify on a single expression and return a NamedTuple with all key
metrics for comparison.
"""
function run_section_benchmark(label, input_expr; config::RunConfig = RunConfig())
    t_input = expression_term(input_expr)
    before = compute_quick_metrics(t_input)
    start = time()
    result = simplify(t_input; config = config)
    elapsed = time() - start
    t_best = expression_term(result.best_expr)
    after = compute_quick_metrics(t_best)
    return (
        label = label,
        accepted = result.accepted,
        score_before = result.score_before,
        score_after = result.score_after,
        delta = result.score_before - result.score_after,
        node_count_before = before.node_count,
        node_count_after = after.node_count,
        ser_len_before = before.serialized_len,
        ser_len_after = after.serialized_len,
        denom_before = before.denominator_complexity,
        denom_after = after.denominator_complexity,
        validated = result.validation_passed,
        worst_abs = result.worst_abs_error,
        worst_rel = result.worst_rel_error,
        runtime = elapsed,
        reason = result.stats.terminated_reason,
    )
end

function print_section_report(report; io::IO = stdout)
    acc = report.accepted  ? "✓" : "✗"
    val = report.validated ? "✓" : "✗"
    @printf io "%-12s | score %7.1f → %-7.1f (Δ%+7.1f) | nodes %4d→%-4d | ser %5d→%-5d | denom %3d→%-3d | %s %s  %.2fs  %s\n" report.label report.score_before report.score_after report.delta report.node_count_before report.node_count_after report.ser_len_before report.ser_len_after report.denom_before report.denom_after acc val report.runtime report.reason
end

"""
    run_all_section_benchmarks(sections; config=RunConfig())

Run `run_section_benchmark` on each (label, expr) pair and print results.
Returns a Dict{String,NamedTuple} keyed by label.
"""
function run_all_section_benchmarks(sections; config::RunConfig = RunConfig())
    results = Dict{String,NamedTuple}()
    for (label, expr) in sort!(collect(sections))
        r = run_section_benchmark(label, expr; config = config)
        results[label] = r
        print_section_report(r)
    end
    total_rt = sum(r.runtime for (_, r) in results)
    println("─"^80)
    total_acc = count(r -> r.accepted, values(results))
    total_val = count(r -> r.validated, values(results))
    println("  Total: $(length(results)) sections, $total_acc accepted, $total_val validated, $(round(total_rt, digits=2))s")
    return results
end

function print_benchmark_comparison(title::AbstractString, baseline, improved; io::IO = stdout)
    println(io, "─"^80)
    println(io, "  $title")
    println(io, "─"^80)
    @printf io "  %-14s  %12s  %12s  %12s\n" "metric" "baseline" "improved" "Δ"
    @printf io "  %-14s  %12s  %12s  %12s\n" "──────────────" "────────────" "────────────" "────────────"
    for key in [:score_after, :node_count_after, :ser_len_after, :denom_after, :runtime]
        b = getfield(baseline, key)
        i = getfield(improved, key)
        if key === :score_after
            @printf io "  %-14s  %12.1f  %12.1f  %+12.1f\n" string(key) b i (i - b)
        elseif key === :runtime
            @printf io "  %-14s  %12.2fs  %12.2fs  %+12.2fs\n" string(key) b i (i - b)
        else
            @printf io "  %-14s  %12d  %12d  %+12d\n" string(key) b i (i - b)
        end
    end
    @printf io "  %-14s  %12s  %12s\n" "accepted" (baseline.accepted ? "✓" : "✗") (improved.accepted ? "✓" : "✗")
    @printf io "  %-14s  %12s  %12s\n" "validated" (baseline.validated ? "✓" : "✗") (improved.validated ? "✓" : "✗")
    println(io, "─"^80)
end

function run_benchmarks(; config::RunConfig = RunConfig())
    results = BenchmarkResult[]
    improvements = Float64[]
    for case in benchmark_cases()
        expr = _load_case_expression(case)
        if expr === nothing
            push!(results, BenchmarkResult(case = case, parsed = false, accepted = false, score_before = NaN, score_after = NaN, output_hash = "", terminated_reason = :parse_unavailable))
            continue
        end
        result = simplify(expr; config = config)
        improvement = result.score_before - result.score_after
        push!(improvements, improvement)
        push!(results, BenchmarkResult(
            case = case,
            parsed = true,
            accepted = result.accepted,
            score_before = result.score_before,
            score_after = result.score_after,
            output_hash = structural_hash(result.best_expr),
            terminated_reason = result.stats.terminated_reason,
        ))
    end
    accepted_count = count(r -> r.accepted, results)
    total_count = length(results)
    median_improvement = isempty(improvements) ? NaN : Statistics.median(improvements)
    return BenchmarkSummary(results = results, accepted_count = accepted_count, total_count = total_count, median_improvement = median_improvement)
end
