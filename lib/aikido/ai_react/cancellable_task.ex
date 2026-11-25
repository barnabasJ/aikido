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
    run_subscribed_attempts(owner, request_id, supervisor, work, opts)
  end

  defp run_subscribed_attempts(owner, request_id, supervisor, work, opts) do
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
              do: timeout_result(opts, preflight_deadline, preflight_deadline),
              else:
                execute_attempt(owner, supervisor, work, opts, subscription, monitor, {0, nil, 0})

          {:error, _} = expired ->
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
        timeout_result(opts, preflight_deadline, preflight_deadline)

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
        timeout_result(opts, preflight_deadline, preflight_deadline)

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

  defp execute_attempt(
         owner,
         supervisor,
         work,
         opts,
         sub,
         monitor,
         retry
       ) do
    case remaining_timeout(opts) do
      0 ->
        timeout_result(opts, now(opts), now(opts))

      timeout ->
        execute_live_attempt(
          owner,
          supervisor,
          work,
          opts,
          sub,
          monitor,
          timeout,
          retry
        )
    end
  end

  defp execute_live_attempt(
         owner,
         supervisor,
         work,
         opts,
         sub,
         monitor,
         timeout,
         {number, previous, streak}
       ) do
    opts = Keyword.put(opts, :attempt_timeout, timeout)
    deadline = now(opts) + timeout
    parent = self()
    key = make_ref()

    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: opts[:tracer])

    observe(opts, number, :started, %{timeout_ms: timeout})

    result =
      case start_attempt(supervisor, work, opts, transfer, parent, key, number) do
        {:ok, task} ->
          await_attempt_result(
            task,
            {key, number},
            sub,
            monitor,
            deadline,
            progress_deadline(opts),
            opts,
            []
          )

        {:error, reason} ->
          {:error, reason}
      end

    if opts[:observe] do
      facts =
        Map.put(result_observation(result), :duration_ms, max(0, now(opts) - deadline + timeout))

      observe(opts, number, :ended, facts)
    end

    signature = if opts[:circuit_threshold], do: failure_signature(result)
    streak = if signature == previous, do: streak + 1, else: 1

    if retry_allowed?(result, number, opts) do
      circuit_open? = signature && opts[:circuit_threshold] && streak >= opts[:circuit_threshold]
      backoff = retry_delay(number, opts)
      delay = if circuit_open?, do: max(backoff, opts[:circuit_backoff]), else: backoff
      delay = min(delay, remaining_budget(opts))

      observe(opts, number, if(circuit_open?, do: :provider_backoff, else: :backoff), %{
        delay_ms: delay
      })

      tag = {make_ref(), :aikido_attempt_backoff}
      timer = AttemptTiming.schedule_at(opts[:timing], self(), tag, now(opts) + delay)

      try do
        receive do
          {:aikido_subscription, ^sub, _} ->
            {:error, :cancelled}

          {:DOWN, ^monitor, :process, _, _} ->
            {:error, :cancelled}

          ^tag ->
            execute_attempt(
              owner,
              supervisor,
              work,
              opts,
              sub,
              monitor,
              {number + 1, signature, streak}
            )
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

    min(timeout, remaining_budget(opts))
  end

  defp remaining_budget(opts) do
    case opts[:deadline_at] do
      nil -> :infinity
      deadline -> max(0, deadline - AttemptTiming.system_ms(opts[:timing]))
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
         {key, number} = attempt,
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
          timeout_result(opts, deadline, progress)
        else
          tag = {key, make_ref(), :aikido_attempt_timeout}
          timer = AttemptTiming.schedule_at(opts[:timing], self(), tag, min(deadline, progress))

          try do
            receive do
              {^task_ref, value} ->
                if now(opts) >= min(deadline, progress),
                  do: timeout_result(opts, deadline, progress),
                  else: value

              {:DOWN, ^task_ref, :process, _, reason} ->
                {:error, reason}

              {^key, :progress} ->
                {:continue, progress_deadline(opts), cleanups}

              {^key, {:cleanup, cleanup}} ->
                {:continue, progress, [cleanup | cleanups]}

              {^key, {:observation, observation}} ->
                observe(opts, number, :wire, observation)
                {:continue, progress, cleanups}

              {^key, {:wire, observation, progressing?}} ->
                observe(opts, number, :wire, observation)

                progress =
                  if progressing?, do: progress_deadline(opts), else: progress

                {:continue, progress, cleanups}

              {:aikido_subscription, ^sub, _} ->
                {:error, :cancelled}

              {:DOWN, ^monitor, :process, _, _} ->
                {:error, :cancelled}

              ^tag ->
                timeout_result(opts, deadline, progress)

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
        await_attempt_result(task, attempt, sub, monitor, deadline, progress, opts, cleanups)

      result ->
        release_attempt_resources(task, key, cleanups, opts, number)
        observe(opts, number, :cleanup, %{})
        result
    end
  end

  defp timeout_result(opts, deadline, progress) do
    phase =
      cond do
        opts[:deadline_at] && AttemptTiming.system_ms(opts[:timing]) >= opts[:deadline_at] ->
          :deadline

        progress < deadline ->
          :stream_idle

        true ->
          :attempt
      end

    case opts[:timeout_error] do
      nil ->
        {:error, :timeout}

      callback ->
        timeout =
          if phase == :stream_idle,
            do: opts[:progress_timeout],
            else: opts[:attempt_timeout] || opts[:timeout]

        {:error, callback.(phase, timeout)}
    end
  end

  defp observe(opts, number, phase, data) do
    if callback = opts[:observe], do: callback.(number, phase, data)
    :ok
  end

  defp result_observation({:error, reason}),
    do:
      Map.put(
        Aikido.AiReact.ModelAttemptObservation.failure(reason),
        :outcome,
        if(reason == :cancelled, do: :cancelled, else: :failed)
      )

  defp result_observation({:ok, _}), do: %{outcome: :completed}
  defp result_observation(_), do: %{}

  defp failure_signature({:error, reason}) do
    case Aikido.AiReact.ModelAttemptObservation.failure(reason) do
      facts when map_size(facts) > 0 -> facts
      _ -> nil
    end
  end

  defp failure_signature(_), do: nil

  defp release_attempt_resources(task, key, cleanups, opts, number) do
    Task.shutdown(task, :brutal_kill)
    key |> drain_cleanups(cleanups, opts, number) |> Enum.each(&run_cleanup/1)
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

  defp drain_cleanups(key, cleanups, opts, number) do
    receive do
      {^key, {:cleanup, cleanup}} ->
        drain_cleanups(key, [cleanup | cleanups], opts, number)

      {^key, {:observation, observation}} ->
        observe(opts, number, :wire, observation)
        drain_cleanups(key, cleanups, opts, number)

      {^key, {:wire, observation, _progressing?}} ->
        observe(opts, number, :wire, observation)
        drain_cleanups(key, cleanups, opts, number)

      {^key, _} ->
        drain_cleanups(key, cleanups, opts, number)
    after
      0 -> cleanups
    end
  end

  defp retire_timer(timing, reference, tag) do
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

  defp now(opts), do: AttemptTiming.monotonic_ms(opts[:timing])

  defp progress_deadline(opts),
    do: now(opts) + Keyword.get(opts, :progress_timeout, opts[:timeout])
end
