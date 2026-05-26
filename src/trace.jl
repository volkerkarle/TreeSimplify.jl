# trace.jl — Event logging, artifact building, and serialisation.
#
# Every simplify() run produces a TraceBuffer of structured events
# (depth progress, candidate scores, validation results, etc.).
# A RunArtifact packages the input/output expressions, scores, and
# trace into a single serialisable object for offline replay or audit.

using Serialization

"""
    TraceEvent

A single event in the trace log.

Fields:
- `event`   – symbol identifier (:run_started, :depth_completed,
              :best_updated, :candidate_generated, :targeted_disabled,
              :hard_case_escalation, :post_simplify, :validation,
              :run_finished)
- `payload` – NamedTuple with event-specific data
"""
Base.@kwdef struct TraceEvent
    event::Symbol
    payload::NamedTuple = NamedTuple()
end

"""
    TraceBuffer

A vector of TraceEvents accumulated during a simplify() run.
"""
Base.@kwdef mutable struct TraceBuffer
    events::Vector{TraceEvent} = Vector{TraceEvent}()
end

"""
    RunArtifact

A complete, serialisable snapshot of a simplification run for
reproducibility and post-hoc analysis.

Fields:
- `input_serialized`   – plain-text serialisation of input expression
- `output_serialized`  – plain-text serialisation of best expression
- `input_hash`         – SHA-1 of input
- `output_hash`        – SHA-1 of output
- `score_before`       – input expression cost
- `score_after`        – output expression cost
- `accepted`           – whether the result was accepted
- `validation_passed`  – whether equivalence was validated
- `terminated_reason`  – why the search stopped
- `trace`              – full TraceBuffer
"""
Base.@kwdef struct RunArtifact
    input_serialized::String
    output_serialized::String
    input_hash::String
    output_hash::String
    score_before::Float64
    score_after::Float64
    accepted::Bool
    validation_passed::Bool
    terminated_reason::Symbol
    trace::TraceBuffer
end

"""
    build_artifact(result, trace) -> RunArtifact

Package a SimplificationResult and TraceBuffer into a RunArtifact
for serialisation.
"""
function build_artifact(result, trace::TraceBuffer)
    return RunArtifact(
        input_serialized = stable_serialize(result.input_expr),
        output_serialized = stable_serialize(result.best_expr),
        input_hash = structural_hash(result.input_expr),
        output_hash = structural_hash(result.best_expr),
        score_before = result.score_before,
        score_after = result.score_after,
        accepted = result.accepted,
        validation_passed = result.validation_passed,
        terminated_reason = result.stats.terminated_reason,
        trace = trace,
    )
end

"""
    save_artifact(path, artifact)

Serialise a RunArtifact to a file using Julia's `Serialization.serialize`.
"""
function save_artifact(path::AbstractString, artifact::RunArtifact)
    open(path, "w") do io
        serialize(io, artifact)
    end
    return path
end

"""
    load_artifact(path) -> RunArtifact

Deserialise a RunArtifact from a file.
"""
function load_artifact(path::AbstractString)
    open(path, "r") do io
        return deserialize(io)
    end
end

"""
    replay_artifact(path) -> NamedTuple

Load an artifact and return a compact summary NamedTuple:
    (input_hash, output_hash, accepted, terminated_reason, score_delta)
"""
function replay_artifact(path::AbstractString)
    artifact = load_artifact(path)
    return (
        input_hash = artifact.input_hash,
        output_hash = artifact.output_hash,
        accepted = artifact.accepted,
        terminated_reason = artifact.terminated_reason,
        score_delta = artifact.score_before - artifact.score_after,
    )
end

"""
    push_event!(buffer, event; payload=NamedTuple())

Append a TraceEvent to the buffer.  Returns the buffer for chaining.
"""
function push_event!(buffer::TraceBuffer, event::Symbol; payload::NamedTuple = NamedTuple())
    push!(buffer.events, TraceEvent(event = event, payload = payload))
    return buffer
end
