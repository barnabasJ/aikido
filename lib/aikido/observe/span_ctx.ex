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

    field :tracer_module, :atom,
      allow_nil?: true,
      description: "Pinned tracer module for this span"

    field :tracer_ctx, :term, allow_nil?: true, description: "Tracer-specific context"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc false
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema

  @doc """
  Creates a new SpanCtx from a map of attributes.

  Returns `{:ok, span_ctx}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    Aikido.Schema.cast(@schema, attrs)
  end

  def new(_), do: {:error, Aikido.Error.validation_error("SpanCtx requires a map")}

  @doc """
  Creates a new SpanCtx from a map, raising on error.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, span_ctx} -> span_ctx
      {:error, reason} -> raise Aikido.Error.validation_error("Invalid SpanCtx", details: reason)
    end
  end
end
