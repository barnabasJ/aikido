defmodule AikidoTest.LifecycleWait do
  @moduledoc "Event-based helpers for process shutdown and supervised agent recovery."

  def await_down(pid, timeout \\ 1_000) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        raise ExUnit.AssertionError, message: "Process #{inspect(pid)} did not stop"
    end
  end

  def restart(pid, timeout \\ 10_000) do
    {:ok, {instance, id, partition}} =
      Aikido.AgentServer.state(pid, &{:ok, {&1.aikido, &1.id, &1.partition}})

    caller = self()
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:aikido, :agent_server, :ready],
        &__MODULE__.agent_ready/4,
        %{
          caller: caller,
          handler: handler,
          instance: instance,
          id: id,
          partition: partition,
          previous: pid
        }
      )

    try do
      Process.exit(pid, :kill)

      receive do
        {^handler, replacement} ->
          :ok = Aikido.AgentServer.await_ready(replacement, timeout: timeout)
          replacement
      after
        timeout -> raise ExUnit.AssertionError, message: "Agent #{inspect(id)} did not restart"
      end
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def agent_ready(_event, _measurements, metadata, config) do
    if metadata.aikido_instance == config.instance and metadata.agent_id == config.id and
         metadata.aikido_partition == config.partition and self() != config.previous do
      send(config.caller, {config.handler, self()})
    end
  end
end
