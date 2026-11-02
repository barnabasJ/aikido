defmodule AikidoTest.AgentCommandGate do
  @moduledoc "Finite OTP debug gates on native agent read and shutdown messages; changes no agent state."

  def install(agent, phase) do
    nonce = make_ref()
    :ok = :sys.install(agent, {nonce, &event/3, %{observer: self(), nonce: nonce, phase: phase}})
    nonce
  end

  def release(agent, nonce), do: send(agent, {nonce, :release})

  def event(
        %{phase: :shutdown} = gate,
        {:in, {:"$gen_call", _, {:durable, {:stop_with_status, :stopped_permanent, :normal}}}},
        _
      ) do
    hold(gate)
  end

  def event(%{phase: :read} = gate, {:in, {:"$gen_call", _, {:read_state_with_selector, _}}}, _) do
    hold(gate)
  end

  def event(gate, _event, _name), do: gate

  defp hold(gate) do
    monitor = Process.monitor(gate.observer)
    send(gate.observer, {gate.nonce, :held, self()})

    try do
      receive do
        {nonce, :release} when nonce == gate.nonce -> :ok
        {:DOWN, ^monitor, :process, _observer, _reason} -> :ok
      after
        8_000 -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end

    :done
  end
end
