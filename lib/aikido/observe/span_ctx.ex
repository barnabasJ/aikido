defmodule Aikido.Observe.SpanCtx do
  @moduledoc """
  Span context for observability tracking.

  Contains all necessary information to finish a span that was started
  with `Aikido.Observe.start_span/2`.
  """

  use Ash.TypedStruct

  typed_struct do
    field :event_prefix, {:array, :atom},
      allow_nil?: false,
      description: "Telemetry event prefix"

    field :start_time, :integer,
      allow_nil?: false,
      description: "Monotonic start time in nanoseconds"

    field :start_system_time, :integer,
      allow_nil?: false,
      description: "System start time in nanoseconds"

    field :metadata, :map, allow_nil?: false, description: "Event metadata"

    field :tracer_module, :term,
      allow_nil?: true,
      description: "Pinned Ash tracer module or modules for this span"

    field :tracer_ctx, :term, allow_nil?: true, description: "Tracer-specific context"
  end

  @type t :: %__MODULE__{}
end
