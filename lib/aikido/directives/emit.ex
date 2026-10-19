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

  alias Aikido.Tracing.Context, as: TraceContext

  require Logger

  @impl true
  def exec(%{signal: signal, dispatch: dispatch}, input_signal, state) do
    cfg = dispatch || state.default_dispatch

    signal =
      case signal do
        %Jido.Signal{} ->
          Aikido.SignalCtx.inherit(signal, input_signal)

        %{} ->
          case Jido.Signal.new(signal) do
            {:ok, signal} -> Aikido.SignalCtx.inherit(signal, input_signal)
            {:error, _} -> signal
          end
      end

    traced_signal =
      case TraceContext.propagate_to(signal, input_signal.id) do
        {:ok, s} -> s
        {:error, _} -> signal
      end

    dispatch_signal(traced_signal, cfg, state)

    :ok
  end

  defp dispatch_signal(traced_signal, nil, _state) do
    send(self(), {:signal, traced_signal})
  end

  defp dispatch_signal(traced_signal, cfg, state) do
    if Code.ensure_loaded?(Jido.Signal.Dispatch) do
      task_sup =
        if state.aikido,
          do: Aikido.task_supervisor_name(state.aikido),
          else: Aikido.TaskSupervisor

      Task.Supervisor.start_child(task_sup, fn ->
        Jido.Signal.Dispatch.dispatch(traced_signal, cfg)
      end)
    else
      Logger.warning("Jido.Signal.Dispatch not available, skipping emit")
    end
  end
end
