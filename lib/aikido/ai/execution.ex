defmodule Aikido.AI.Execution do
  @moduledoc false
  # Runs inside an I/O task, never inside directive execution or an action.
  # The inner task performs one bounded attempt. This owner handles cancellation,
  # deadlines and cleanup; it never writes agent state.
  def run(owner, request_id, supervisor, work, opts) do
    selector = fn runtime ->
      if Enum.any?(runtime.agent.state, fn
           {_, %{request_id: ^request_id, status: status}} when status in [:setup, :running] ->
             true

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
            attempt(owner, supervisor, work, opts, subscription, monitor, deadline, 0)

          _ ->
            {:error, :cancelled}
        end
      after
        Process.demonitor(monitor, [:flush])
        if Process.alive?(owner), do: Aikido.AgentServer.unsubscribe(owner, subscription)
      end
    end
  end

  defp attempt(owner, supervisor, work, opts, sub, monitor, deadline, number) do
    parent = self()
    key = make_ref()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        notify = fn event -> send(parent, {key, event}) end

        try do
          work.(notify, number)
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    result =
      wait(
        task,
        key,
        sub,
        monitor,
        deadline,
        now() + Keyword.get(opts, :progress_timeout, opts[:timeout]),
        opts,
        []
      )

    if Aikido.Exec.Retry.should_retry?(result, number, Keyword.get(opts, :retries, 0), []) &&
         match?({:error, _}, result) && now() < deadline && result != {:error, :cancelled} do
      delay =
        min(
          Aikido.Exec.Retry.calculate_backoff(number, Keyword.get(opts, :backoff, 200)),
          max(deadline - now(), 0)
        )

      receive do
        {:aikido_subscription, ^sub, _} -> {:error, :cancelled}
        {:DOWN, ^monitor, :process, _, _} -> {:error, :cancelled}
      after
        delay ->
          if now() < deadline,
            do: attempt(owner, supervisor, work, opts, sub, monitor, deadline, number + 1),
            else: {:error, :timeout}
      end
    else
      result
    end
  end

  defp wait(task, key, sub, monitor, deadline, progress, opts, cleanups) do
    result =
      receive do
        {ref, value} when ref == task.ref ->
          Process.demonitor(task.ref, [:flush])
          value

        {:DOWN, ref, :process, _, reason} when ref == task.ref ->
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
        wait(task, key, sub, monitor, deadline, progress, opts, cleanups)

      result ->
        Task.shutdown(task, :brutal_kill)

        Enum.each(drain_cleanups(key, cleanups), fn cleanup ->
          try do
            cleanup.()
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        result
    end
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
