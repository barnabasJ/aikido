defmodule Aikido.Directives.Emit do
  @moduledoc """
  Dispatch a signal via `Jido.Signal.Dispatch`.

  The runtime interprets this directive by calling:

      Jido.Signal.Dispatch.dispatch(signal, dispatch_config)

  ## Fields

  - `signal` - A `Jido.Signal.t()` struct to dispatch
  - `dispatch` - Dispatch config: `{adapter, opts}` or list of configs
    - `:pid` - Direct to process
    - `:pubsub` - Via PubSub
    - `:bus` - To signal bus
    - `:http` / `:webhook` - HTTP endpoints
    - `:logger` / `:console` / `:noop` - Logging/testing

  If `dispatch` is omitted and the agent has no `default_dispatch`, runtime
  falls back to emitting to the current agent process (`self()`).

  ## Examples

      # Use agent's default dispatch (configured on AgentServer)
      %Emit{signal: signal}

      # Explicit dispatch to PubSub
      %Emit{signal: signal, dispatch: {:pubsub, topic: "events"}}

      # Multiple dispatch targets
      %Emit{signal: signal, dispatch: [
        {:pubsub, topic: "events"},
        {:logger, level: :info}
      ]}
  """

  use Ash.TypedStruct

  typed_struct do
    field :signal, :term, allow_nil?: false, description: "Jido.Signal.t() to dispatch"

    field :dispatch, :term,
      allow_nil?: true,
      description: "Dispatch config: {adapter, opts} or list"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Emit."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema
end
