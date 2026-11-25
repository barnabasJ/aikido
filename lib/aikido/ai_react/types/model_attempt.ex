defmodule Aikido.AiReact.Types.ModelAttempt do
  @moduledoc "Typed, payload-free facts for one model attempt; absent values remain unknown."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        outcome: [type: Aikido.AiReact.Types.ModelAttemptOutcome],
        terminal_outcome: [type: Aikido.AiReact.Types.ModelAttemptOutcome],
        request_id: [type: :string],
        iteration: [type: :integer],
        attempt: [type: :integer],
        mode: [type: Aikido.AiReact.Types.RequestMode],
        handoff_id: [type: :integer],
        phase: [type: Aikido.AiReact.Types.ModelAttemptPhase],
        deadline_at: [type: :integer],
        absolute_deadline_at: [type: :integer, constraints: [min: 1]],
        timeout_ms: [type: :integer],
        duration_ms: [type: :integer, constraints: [min: 0]],
        started_at: [type: :integer],
        ended_at: [type: :integer],
        cleanup_at: [type: :integer],
        delivered_at: [type: :integer],
        first_chunk_at: [type: :integer],
        first_progress_at: [type: :integer],
        opened: [type: :boolean],
        wire_chunks: [type: :integer],
        qualifying_chunks: [type: :integer],
        nonqualifying_chunks: [type: :integer],
        rendered_chunks: [type: :integer],
        status: [type: :integer],
        cause_type: [type: :atom],
        transport_type: [type: :atom],
        transport_reason: [type: Aikido.AiReact.Types.ProviderTransportReason],
        timeout_phase: [type: Aikido.AiReact.Types.ModelTimeoutPhase],
        delay_ms: [type: :integer],
        retry_at: [type: :integer]
      ]
    ]
end
