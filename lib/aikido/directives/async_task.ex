defmodule Aikido.Directives.AsyncTask do
  @moduledoc """
  Run blocking work under the agent's task supervisor and report back by signal.

  `Spawn` is the low-level fire-and-forget primitive. Use `AsyncTask` when
  the work has a result that should re-enter the agent's normal signal routes.
  The executor starts a supervised task, normalizes the task's return value, and
  casts one or more signals back to the originating agent.

  The work may return a fully-built `%Aikido.Signal{}` when it needs complete
  control over the reply envelope. Otherwise, ordinary `{:ok, value}` and
  `{:error, reason}` results are wrapped using `success_type` and `error_type`.

  ## Result normalization

      %Aikido.Signal{} -> signal is cast back as-is
      {:ok, %Aikido.Signal{}} -> signal is cast back as-is
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
    field :work, :term do
      allow_nil? false
      description "MFA or function to execute in a supervised task"
    end

    field :success_type, :string do
      allow_nil? false
      default @default_success_type
      description "Signal type emitted for successful non-signal results"
      constraints trim?: false, allow_empty?: true
    end

    field :error_type, :string do
      allow_nil? false
      default @default_error_type
      description "Signal type emitted for errors, exits, throws, and crashes"
      constraints trim?: false, allow_empty?: true
    end

    field :payload, :map do
      allow_nil? false
      default %{}
      description "Static payload merged into reply data"
    end

    field :source, :string do
      allow_nil? true
      description "Signal source for generated reply signals"
      constraints trim?: false, allow_empty?: true
    end

    field :target, :term do
      allow_nil? true
      description "GenServer target for reply signals; defaults to originating agent"
    end
  end

  alias Aikido.AgentServer
  alias Aikido.AgentServer.State
  alias Aikido.Directives.AsyncTask
  alias Aikido.Signal

  require Ash.Tracer
  require Logger

  @spec exec(directive :: AsyncTask.t(), input_signal :: Signal.t(), state :: State.t()) :: :ok
  @impl true
  def exec(%AsyncTask{} = directive, input_signal, %State{} = state) do
    case start(directive, input_signal, state) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        directive
        |> error_signal(reason, state)
        |> send_result_signals_to_target(input_signal, result_recipient(directive, self()), state)
    end

    :ok
  end

  @doc false
  @spec start(AsyncTask.t(), Signal.t(), State.t()) :: {:ok, pid()} | {:error, term()}
  def start(%AsyncTask{} = directive, %Signal{} = input_signal, %State{} = state) do
    agent_pid = self()
    tracers = Aikido.Signal.tracers(input_signal, state.aikido)
    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)

    Task.Supervisor.start_child(Aikido.task_supervisor_name(state.aikido), fn ->
      Ash.ProcessHelpers.transfer_context(transfer)

      Ash.Tracer.span {:custom, :aikido_async_task}, "aikido.async_task", tracers do
        run_work_and_send_result_signals(directive, input_signal, state, agent_pid)
      end
    end)
  end

  @spec run_work_and_send_result_signals(
          directive :: AsyncTask.t(),
          input_signal :: Signal.t(),
          state :: State.t(),
          agent_pid :: pid()
        ) :: :ok
  defp run_work_and_send_result_signals(
         %AsyncTask{} = directive,
         %Signal{} = input_signal,
         %State{} = state,
         agent_pid
       ) do
    signals =
      directive
      |> run_work(input_signal, state)
      |> result_signals(directive, state)

    send_result_signals_to_target(
      signals,
      input_signal,
      result_recipient(directive, agent_pid),
      state
    )
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

  @spec result_signals(result :: term(), directive :: AsyncTask.t(), state :: State.t()) :: [
          Signal.t()
        ]
  defp result_signals(%Signal{} = signal, _directive, _state), do: [signal]
  defp result_signals({:ok, %Signal{} = signal}, _directive, _state), do: [signal]
  defp result_signals({:signals, signals}, _directive, _state), do: filter_signal_structs(signals)

  defp result_signals({:ok, {:signals, signals}}, _directive, _state),
    do: filter_signal_structs(signals)

  defp result_signals({:ok, result}, %AsyncTask{} = directive, %State{} = state) do
    [success_signal(directive, result, state)]
  end

  defp result_signals(
         {:error, %{kind: kind, reason: reason}},
         %AsyncTask{} = directive,
         %State{} = state
       ) do
    [error_signal(directive, reason, state, %{kind: kind})]
  end

  defp result_signals({:error, reason}, %AsyncTask{} = directive, %State{} = state) do
    [error_signal(directive, reason, state)]
  end

  defp result_signals(result, %AsyncTask{} = directive, %State{} = state) do
    [success_signal(directive, result, state)]
  end

  @spec filter_signal_structs(signals :: term()) :: [Signal.t()]
  defp filter_signal_structs(signals) when is_list(signals) do
    Enum.filter(signals, &match?(%Signal{}, &1))
  end

  defp filter_signal_structs(_signals), do: []

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

  @spec result_recipient(directive :: AsyncTask.t(), agent_pid :: pid()) :: GenServer.server()
  defp result_recipient(%AsyncTask{target: nil}, agent_pid), do: agent_pid
  defp result_recipient(%AsyncTask{target: target}, _agent_pid), do: target

  @spec send_result_signals_to_target(
          signals :: [Signal.t()] | Signal.t(),
          input_signal :: Signal.t(),
          target :: GenServer.server(),
          state :: State.t()
        ) :: :ok
  defp send_result_signals_to_target(
         %Signal{} = signal,
         %Signal{} = input_signal,
         target,
         %State{} = state
       ) do
    send_result_signals_to_target([signal], input_signal, target, state)
  end

  defp send_result_signals_to_target(signals, %Signal{} = input_signal, target, %State{} = state)
       when is_list(signals) do
    Enum.each(signals, fn signal ->
      send_signal_or_log_failure(target, Aikido.Signal.inherit(signal, input_signal), state)
    end)

    :ok
  end

  @spec send_signal_or_log_failure(
          target :: GenServer.server(),
          signal :: Signal.t(),
          state :: State.t()
        ) :: :ok
  defp send_signal_or_log_failure(target, %Signal{} = signal, %State{} = state) do
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
