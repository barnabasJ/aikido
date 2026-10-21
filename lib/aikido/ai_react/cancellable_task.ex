defmodule Aikido.AiReact.CancellableTask do
  @moduledoc """
  Owns cancellable I/O attempts for a ReAct model call or tool setup/execution.

  Runs in supervised work outside the agent mailbox. It retries eligible
  failures, enforces total and progress deadlines, and releases cleanup
  callbacks when work finishes or the owning run ends. It never writes state.
  """
  require Ash.Tracer
  require Logger

  @doc "Run bounded I/O attempts, retry eligible failures, and cancel when the owning run ends."
  def run_cancellable_attempts(owner, request_id, supervisor, work, opts) do
    selector = fn runtime ->
      if Enum.any?(runtime.agent.state, fn
           {_, %{request_id: ^request_id, status: status} = slice}
           when status in [:setup, :running] ->
             Map.get(slice, :hook_terminal) not in [:completed, :failed]

           _ ->
             false
         end), do: :skip, else: {:error, :cancelled}
    end

    with {:ok, subscription} <-
           Aikido.AgentServer.subscribe(owner, "ai.react.**", selector, once: true) do
      monitor = Process.monitor(owner)
      deadline = now() + Keyword.fetch!(opts, :timeout)

      try do
        case Aikido.AgentServer.state(owner, &{:ok, selector.(&1)}) do
          {:ok, :skip} ->
            execute_attempt(owner, supervisor, work, opts, subscription, monitor, deadline, 0)

          _ ->
            {:error, :cancelled}
        end
      after
        Process.demonitor(monitor, [:flush])
        if Process.alive?(owner), do: Aikido.AgentServer.unsubscribe(owner, subscription)
      end
    end
  end

  defp execute_attempt(owner, supervisor, work, opts, sub, monitor, deadline, number) do
    parent = self()
    key = make_ref()

    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: opts[:tracer])

    result =
      case start_attempt(supervisor, work, opts, transfer, parent, key, number) do
        {:ok, task} ->
          await_attempt_result(
            task,
            key,
            sub,
            monitor,
            deadline,
            now() + Keyword.get(opts, :progress_timeout, opts[:timeout]),
            opts,
            []
          )

        {:error, reason} ->
          {:error, reason}
      end

    if retry_allowed?(result, number, deadline, opts) do
      delay = retry_delay(number, deadline, opts)

      receive do
        {:aikido_subscription, ^sub, _} -> {:error, :cancelled}
        {:DOWN, ^monitor, :process, _, _} -> {:error, :cancelled}
      after
        delay ->
          if now() < deadline,
            do:
              execute_attempt(owner, supervisor, work, opts, sub, monitor, deadline, number + 1),
            else: {:error, :timeout}
      end
    else
      result
    end
  end

  defp retry_allowed?(result, number, deadline, opts) do
    number < Keyword.get(opts, :retries, 0) && Aikido.Error.retryable?(result) &&
      match?({:error, _}, result) && now() < deadline && result != {:error, :cancelled}
  end

  defp retry_delay(number, deadline, opts) do
    backoff = round(Keyword.get(opts, :backoff, 200) * :math.pow(2, number))
    min(min(backoff, 30_000), max(deadline - now(), 0))
  end

  defp start_attempt(supervisor, work, opts, transfer, parent, key, number) do
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ash.ProcessHelpers.transfer_context(transfer)
        notify = fn event -> send(parent, {key, event}) end

        try do
          Ash.Tracer.span {:custom, :aikido_attempt}, "aikido.attempt.#{number}", opts[:tracer] do
            work.(notify, number)
          end
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    {:ok, task}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp await_attempt_result(
         %Task{ref: task_ref} = task,
         key,
         sub,
         monitor,
         deadline,
         progress,
         opts,
         cleanups
       ) do
    result =
      receive do
        {^task_ref, value} ->
          value

        {:DOWN, ^task_ref, :process, _, reason} ->
          {:error, reason}

        {^key, :progress} ->
          {:continue, now() + Keyword.get(opts, :progress_timeout, opts[:timeout]), cleanups}

        {^key, {:cleanup, cleanup}} ->
          {:continue, progress, [cleanup | cleanups]}

        {:aikido_subscription, ^sub, _} ->
          {:error, :cancelled}

        {:DOWN, ^monitor, :process, _, _} ->
          {:error, :cancelled}
      after
        max(min(deadline, progress) - now(), 0) -> {:error, :timeout}
      end

    case result do
      {:continue, progress, cleanups} ->
        await_attempt_result(task, key, sub, monitor, deadline, progress, opts, cleanups)

      result ->
        release_attempt_resources(task, key, cleanups)
        result
    end
  end

  defp release_attempt_resources(task, key, cleanups) do
    Task.shutdown(task, :brutal_kill)
    key |> drain_cleanups(cleanups) |> Enum.each(&run_cleanup/1)
  end

  defp run_cleanup(cleanup) do
    cleanup.()
  rescue
    error ->
      Logger.warning(
        "AI cleanup callback raised: #{Aikido.Telemetry.Formatter.safe_inspect(error)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "AI cleanup callback #{kind}: #{Aikido.Telemetry.Formatter.safe_inspect(reason)}"
      )
  end

  defp drain_cleanups(key, cleanups) do
    receive do
      {^key, {:cleanup, cleanup}} -> drain_cleanups(key, [cleanup | cleanups])
      {^key, _} -> drain_cleanups(key, cleanups)
    after
      0 -> cleanups
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
