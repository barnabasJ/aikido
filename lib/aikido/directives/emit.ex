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

  use Aikido.Directive

  typed_struct do
    field :signal, :term, allow_nil?: false, description: "Jido.Signal.t() to dispatch"

    field :dispatch, :term,
      allow_nil?: true,
      description: "Dispatch config: {adapter, opts} or list"
  end

  @impl true
  def exec(%{signal: signal, dispatch: dispatch}, input_signal, state) do
    cfg = dispatch || state.default_dispatch

    signal =
      signal
      |> Aikido.Directive.materialize_signal()
      |> Aikido.SignalCtx.inherit(input_signal)

    dispatch_signal(signal, cfg, state)

    :ok
  end

  defp dispatch_signal(signal, nil, _state) do
    send(self(), {:signal, signal})
  end

  defp dispatch_signal(signal, cfg, state) do
    transfer = Aikido.SignalCtx.tracer_context(signal)

    Task.Supervisor.start_child(Aikido.task_supervisor_name(state.aikido), fn ->
      Ash.ProcessHelpers.transfer_context(transfer)
      Jido.Signal.Dispatch.dispatch(signal, cfg)
    end)
  end
end
