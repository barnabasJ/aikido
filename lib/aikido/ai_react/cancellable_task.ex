defmodule Aikido.AiReact.CancellableTask do
  @moduledoc """
  Owns cancellable I/O attempts for a ReAct model call or tool setup/execution.

  Runs in supervised work outside the agent mailbox. It retries eligible
  failures, enforces per-attempt and progress deadlines, and releases cleanup
  callbacks when work finishes or the owning run ends. It never writes state.
  """
  require Ash.Tracer
  require Logger
  alias Aikido.AiReact.AttemptTiming

  @doc "Run bounded I/O attempts, retry eligible failures, and cancel when the owning run ends."
  def run_cancellable_attempts(owner, request_id, supervisor, work, opts) do
    opts = Keyword.put(opts, :timing, AttemptTiming.resolve(opts[:timing]))

    selector = fn runtime ->
      run_active? =
        Enum.any?(runtime.agent.state, fn
          {_, %{request_id: ^request_id, status: status} = slice}
          when status in [:setup, :running] ->
            Map.get(slice, :hook_terminal) not in [:completed, :failed] &&
              (is_nil(opts[:generation]) ||
                 Map.get(slice, :tools_generation) == opts[:generation])

          _ ->
            false
        end)

      if run_active?, do: :skip, else: {:error, :cancelled}
    end

    preflight_deadline = now(opts) + remaining_timeout(opts)

    with {:ok, subscription} <-
           subscribe_for_cancellation(owner, selector, opts, preflight_deadline) do
      monitor = Process.monitor(owner)

      try do
        case read_run_after_subscription(owner, selector, opts, preflight_deadline) do
          {:ok, :skip} ->
            if preflight_timeout(opts, preflight_deadline) == 0,
              do: {:error, :timeout},
              else: execute_attempt(owner, supervisor, work, opts, subscription, monitor, 0)

          {:error, :timeout} = expired ->
            expired

          _ ->
            {:error, :cancelled}
        end
      after
        Process.demonitor(monitor, [:flush])

        if Process.alive?(owner), do: Aikido.AgentServer.unsubscribe(owner, subscription)
      end
    end
  catch
    :exit, reason -> {:error, {:owner_unavailable, reason}}
  end

  defp subscribe_for_cancellation(owner, selector, opts, preflight_deadline) do
    case preflight_timeout(opts, preflight_deadline) do
      0 ->
        {:error, :timeout}

      budget ->
        Aikido.AgentServer.subscribe(owner, "ai.react.**", selector,
          once: true,
          timeout: AttemptTiming.control_timeout(opts[:timing], budget)
        )
    end
  catch
    :exit, {:timeout, {GenServer, :call, _request}} -> {:error, :timeout}
  end

  defp read_run_after_subscription(owner, selector, opts, preflight_deadline) do
    case preflight_timeout(opts, preflight_deadline) do
      0 ->
        {:error, :timeout}

      budget ->
        Aikido.AgentServer.state(owner, &{:ok, selector.(&1)},
          timeout: AttemptTiming.control_timeout(opts[:timing], budget)
        )
    end
  catch
    :exit, {:timeout, {GenServer, :call, _request}} -> {:error, :timeout}
  end

  defp preflight_timeout(opts, preflight_deadline) do
    max(0, min(preflight_deadline - now(opts), remaining_timeout(opts)))
  end

  defp execute_attempt(owner, supervisor, work, opts, sub, monitor, number) do
    case remaining_timeout(opts) do
      0 ->
        {:error, :timeout}

      timeout ->
        execute_live_attempt(owner, supervisor, work, opts, sub, monitor, number, timeout)
    end
  end

  defp execute_live_attempt(owner, supervisor, work, opts, sub, monitor, number, timeout) do
    deadline = now(opts) + timeout
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
            now(opts) + Keyword.get(opts, :progress_timeout, opts[:timeout]),
            opts,
            []
          )

        {:error, reason} ->
          {:error, reason}
      end

    if retry_allowed?(result, number, opts) do
      delay = min(retry_delay(number, opts), remaining_timeout(opts))

      tag = {make_ref(), :aikido_attempt_backoff}
      timer = AttemptTiming.schedule_at(opts[:timing], self(), tag, now(opts) + delay)

      try do
        receive do
          {:aikido_subscription, ^sub, _} -> {:error, :cancelled}
          {:DOWN, ^monitor, :process, _, _} -> {:error, :cancelled}
          ^tag -> execute_attempt(owner, supervisor, work, opts, sub, monitor, number + 1)
        end
      after
        retire_timer(opts[:timing], timer, tag)
      end
    else
      result
    end
  end

  defp remaining_timeout(opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    case opts[:deadline_at] do
      nil -> timeout
      deadline -> max(0, min(timeout, deadline - AttemptTiming.system_ms(opts[:timing])))
    end
  end

  defp retry_allowed?(result, number, opts) do
    remaining_timeout(opts) > 0 && number < Keyword.get(opts, :retries, 0) &&
      Aikido.Error.retryable?(result) &&
      match?({:error, _}, result) && result != {:error, :cancelled}
  end

  defp retry_delay(number, opts) do
    backoff = round(Keyword.get(opts, :backoff, 200) * :math.pow(2, number))
    min(backoff, 30_000)
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
      try do
        remaining = min(deadline, progress) - now(opts)

        if remaining <= 0 do
          {:error, :timeout}
        else
          tag = {key, make_ref(), :aikido_attempt_timeout}
          timer = AttemptTiming.schedule_at(opts[:timing], self(), tag, min(deadline, progress))

          try do
            receive do
              {^task_ref, value} ->
                value

              {:DOWN, ^task_ref, :process, _, reason} ->
                {:error, reason}

              {^key, :progress} ->
                {:continue, now(opts) + Keyword.get(opts, :progress_timeout, opts[:timeout]),
                 cleanups}

              {^key, {:cleanup, cleanup}} ->
                {:continue, progress, [cleanup | cleanups]}

              {:aikido_subscription, ^sub, _} ->
                {:error, :cancelled}

              {:DOWN, ^monitor, :process, _, _} ->
                {:error, :cancelled}

              ^tag ->
                {:error, :timeout}

              {^key, _retired_generation, :aikido_attempt_timeout} ->
                {:continue, progress, cleanups}
            end
          after
            retire_timer(opts[:timing], timer, tag)
          end
        end
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
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

  defp retire_timer(timing, reference, tag) do
    try do
      AttemptTiming.cancel_timer(timing, reference)
    rescue
      _error ->
        Logger.warning("Attempt timer cancellation failed; retired timer tags remain ignored.")
    catch
      _kind, _reason ->
        Logger.warning("Attempt timer cancellation failed; retired timer tags remain ignored.")
    after
      receive do
        ^tag -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp now(opts), do: AttemptTiming.monotonic_ms(opts[:timing])
end
