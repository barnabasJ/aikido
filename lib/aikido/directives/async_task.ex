defmodule Aikido.Directives.AsyncTask do
  @moduledoc """
  Run blocking work under the agent's task supervisor and report back by signal.

  `Spawn` is the low-level fire-and-forget primitive. Use `AsyncTask` when
  the work has a result that should re-enter the agent's normal signal routes.
  The executor starts a supervised task, normalizes the task's return value, and
  casts one or more signals back to the originating agent.

  The work may return a fully-built `%Jido.Signal{}` when it needs complete
  control over the reply envelope. Otherwise, ordinary `{:ok, value}` and
  `{:error, reason}` results are wrapped using `success_type` and `error_type`.

  ## Result normalization

      %Jido.Signal{} -> signal is cast back as-is
      {:ok, %Jido.Signal{}} -> signal is cast back as-is
      {:signals, signals} -> all signals are cast back
      {:ok, {:signals, signals}} -> all signals are cast back
      {:ok, result} -> success signal with payload + %{result: result}
      {:error, reason} -> error signal with payload + %{reason: reason}
      other -> success signal with payload + %{result: other}
  """

  @default_success_type "aikido.async_task.completed"
  @default_error_type "aikido.async_task.failed"

  @type work :: {module :: module(), function :: atom(), args :: [term()]} | function()
  @type target :: GenServer.server() | nil

  use Aikido.Directive

  typed_struct do
    field :work, :term,
      allow_nil?: false,
      description: "MFA or function to execute in a supervised task"

    field :success_type, :string,
      allow_nil?: false,
      default: @default_success_type,
      description: "Signal type emitted for successful non-signal results",
      constraints: [trim?: false, allow_empty?: true]

    field :error_type, :string,
      allow_nil?: false,
      default: @default_error_type,
      description: "Signal type emitted for errors, exits, throws, and crashes",
      constraints: [trim?: false, allow_empty?: true]

    field :payload, :map,
      allow_nil?: false,
      default: %{},
      description: "Static payload merged into reply data"

    field :source, :string,
      allow_nil?: true,
      description: "Signal source for generated reply signals",
      constraints: [trim?: false, allow_empty?: true]

    field :target, :term,
      allow_nil?: true,
      description: "GenServer target for reply signals; defaults to originating agent"
  end

  alias Aikido.AgentServer
  alias Aikido.AgentServer.State
  alias Aikido.Directives.AsyncTask
  alias Jido.Signal
  alias Aikido.Tracing.Context, as: TraceContext

  require Logger

  @spec exec(directive :: AsyncTask.t(), input_signal :: Signal.t(), state :: State.t()) :: :ok
  @impl true
  def exec(%AsyncTask{} = directive, input_signal, %State{} = state) do
    agent_pid = self()
    task_sup = task_supervisor(state)

    case Task.Supervisor.start_child(task_sup, fn ->
           run_and_dispatch(directive, input_signal, state, agent_pid)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        directive
        |> error_signal(reason, state)
        |> dispatch_signals(input_signal, reply_target(directive, agent_pid), state)
    end

    :ok
  end

  @spec task_supervisor(state :: State.t()) :: module()
  defp task_supervisor(%State{} = state) do
    if state.aikido, do: Aikido.task_supervisor_name(state.aikido), else: Aikido.TaskSupervisor
  end

  @spec run_and_dispatch(
          directive :: AsyncTask.t(),
          input_signal :: Signal.t(),
          state :: State.t(),
          agent_pid :: pid()
        ) :: :ok
  defp run_and_dispatch(
         %AsyncTask{} = directive,
         %Signal{} = input_signal,
         %State{} = state,
         agent_pid
       ) do
    signals =
      directive
      |> run_work(input_signal, state)
      |> normalize_result(directive, state)

    dispatch_signals(signals, input_signal, reply_target(directive, agent_pid), state)
  end

  @spec run_work(directive :: AsyncTask.t(), input_signal :: Signal.t(), state :: State.t()) ::
          term()
  defp run_work(%AsyncTask{work: work}, %Signal{} = input_signal, %State{} = state) do
    invoke_work(work, task_context(input_signal, state))
  rescue
    exception ->
      {:error, %{kind: :error, reason: exception, stacktrace: __STACKTRACE__}}
  catch
    kind, reason ->
      {:error, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
  end

  @spec invoke_work(work :: AsyncTask.work(), context :: map()) :: term()
  defp invoke_work({module, function, args}, _context)
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  end

  defp invoke_work(fun, _context) when is_function(fun, 0), do: fun.()
  defp invoke_work(fun, context) when is_function(fun, 1), do: fun.(context)
  defp invoke_work(other, _context), do: {:error, {:invalid_async_task_work, other}}

  @spec task_context(input_signal :: Signal.t(), state :: State.t()) :: map()
  defp task_context(%Signal{} = input_signal, %State{} = state) do
    %{
      agent_id: state.id,
      input_signal: input_signal,
      aikido: state.aikido,
      partition: state.partition
    }
  end

  @spec normalize_result(result :: term(), directive :: AsyncTask.t(), state :: State.t()) :: [
          Signal.t()
        ]
  defp normalize_result(%Signal{} = signal, _directive, _state), do: [signal]
  defp normalize_result({:ok, %Signal{} = signal}, _directive, _state), do: [signal]
  defp normalize_result({:signals, signals}, _directive, _state), do: valid_signals(signals)

  defp normalize_result({:ok, {:signals, signals}}, _directive, _state),
    do: valid_signals(signals)

  defp normalize_result({:ok, result}, %AsyncTask{} = directive, %State{} = state) do
    [success_signal(directive, result, state)]
  end

  defp normalize_result(
         {:error, %{kind: kind, reason: reason}},
         %AsyncTask{} = directive,
         %State{} = state
       ) do
    [error_signal(directive, reason, state, %{kind: kind})]
  end

  defp normalize_result({:error, reason}, %AsyncTask{} = directive, %State{} = state) do
    [error_signal(directive, reason, state)]
  end

  defp normalize_result(result, %AsyncTask{} = directive, %State{} = state) do
    [success_signal(directive, result, state)]
  end

  @spec valid_signals(signals :: term()) :: [Signal.t()]
  defp valid_signals(signals) when is_list(signals) do
    Enum.filter(signals, &match?(%Signal{}, &1))
  end

  defp valid_signals(_signals), do: []

  @spec success_signal(directive :: AsyncTask.t(), result :: term(), state :: State.t()) ::
          Signal.t()
  defp success_signal(%AsyncTask{} = directive, result, %State{} = state) do
    data = Map.put(directive.payload, :result, result)
    Signal.new!(directive.success_type, data, source: signal_source(directive, state))
  end

  @spec error_signal(
          directive :: AsyncTask.t(),
          reason :: term(),
          state :: State.t(),
          extra :: map()
        ) :: Signal.t()
  defp error_signal(%AsyncTask{} = directive, reason, %State{} = state, extra \\ %{}) do
    data =
      directive.payload
      |> Map.merge(extra)
      |> Map.put(:reason, reason)

    Signal.new!(directive.error_type, data, source: signal_source(directive, state))
  end

  @spec signal_source(directive :: AsyncTask.t(), state :: State.t()) :: String.t()
  defp signal_source(%AsyncTask{source: source}, _state) when is_binary(source), do: source
  defp signal_source(_directive, %State{} = state), do: "/agent/#{state.id}/async_task"

  @spec reply_target(directive :: AsyncTask.t(), agent_pid :: pid()) :: GenServer.server()
  defp reply_target(%AsyncTask{target: nil}, agent_pid), do: agent_pid
  defp reply_target(%AsyncTask{target: target}, _agent_pid), do: target

  @spec dispatch_signals(
          signals :: [Signal.t()] | Signal.t(),
          input_signal :: Signal.t(),
          target :: GenServer.server(),
          state :: State.t()
        ) :: :ok
  defp dispatch_signals(%Signal{} = signal, %Signal{} = input_signal, target, %State{} = state) do
    dispatch_signals([signal], input_signal, target, state)
  end

  defp dispatch_signals(signals, %Signal{} = input_signal, target, %State{} = state)
       when is_list(signals) do
    Enum.each(signals, fn signal -> safe_cast(target, trace(signal, input_signal), state) end)
    :ok
  end

  @spec trace(signal :: Signal.t(), input_signal :: Signal.t()) :: Signal.t()
  defp trace(%Signal{} = signal, %Signal{} = input_signal) do
    signal = Aikido.SignalCtx.inherit(signal, input_signal)

    case TraceContext.propagate_to(signal, input_signal.id) do
      {:ok, traced} -> traced
      {:error, _reason} -> signal
    end
  end

  @spec safe_cast(target :: GenServer.server(), signal :: Signal.t(), state :: State.t()) :: :ok
  defp safe_cast(target, %Signal{} = signal, %State{} = state) do
    _ = AgentServer.cast(target, signal)
    :ok
  rescue
    exception ->
      Logger.warning(
        "AgentServer #{state.id} async task could not cast #{signal.type} to #{inspect(target)}: " <>
          Exception.message(exception)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "AgentServer #{state.id} async task could not cast #{signal.type} to #{inspect(target)}: " <>
          inspect(reason)
      )

      :ok
  end
end
