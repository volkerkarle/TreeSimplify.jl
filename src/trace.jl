using Serialization

Base.@kwdef struct TraceEvent
    event::Symbol
    payload::NamedTuple = NamedTuple()
end

Base.@kwdef mutable struct TraceBuffer
    events::Vector{TraceEvent} = Vector{TraceEvent}()
end

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

function save_artifact(path::AbstractString, artifact::RunArtifact)
    open(path, "w") do io
        serialize(io, artifact)
    end
    return path
end

function load_artifact(path::AbstractString)
    open(path, "r") do io
        return deserialize(io)
    end
end

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

function push_event!(buffer::TraceBuffer, event::Symbol; payload::NamedTuple = NamedTuple())
    push!(buffer.events, TraceEvent(event = event, payload = payload))
    return buffer
end
