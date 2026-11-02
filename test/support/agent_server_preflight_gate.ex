defmodule AikidoTest.AgentServerPreflightGate do
  @moduledoc "A finite OTP debug trigger on one actual AgentServer I/O call; changes no agent state."

  def install(owner, caller, phase, hold_ms) do
    nonce = make_ref()

    context = %{
      observer: self(),
      caller: caller,
      phase: phase,
      hold_ms: hold_ms,
      nonce: nonce,
      registered?: false,
      held?: false
    }

    :ok = :sys.install(owner, {nonce, &event/3, context})
    nonce
  end

  def release(owner, nonce), do: send(owner, {nonce, :release})

  def event(context, {:out, {:ok, reference}, {caller, _tag}, _state}, _name)
      when caller == context.caller and is_reference(reference) do
    send(context.observer, {context.nonce, :registered, self(), reference})

    if context.phase == :subscribe and context.held?,
      do: :done,
      else: %{context | registered?: true}
  end

  def event(
        %{phase: phase, registered?: true} = context,
        {:in, {:"$gen_call", {caller, _tag}, {:read_state_with_selector, _selector}}},
        _name
      )
      when caller == context.caller and phase in [:state, :both] do
    hold(%{context | phase: :state})
    :done
  end

  def event(
        %{phase: phase, held?: false} = context,
        {:in, {:"$gen_call", {caller, _tag}, {:subscribe, _, _, _, _, _, _}}},
        _name
      )
      when caller == context.caller and phase in [:subscribe, :both] do
    hold(%{context | phase: :subscribe})
    %{context | held?: true}
  end

  def event(context, _event, _name), do: context

  defp hold(context) do
    monitor = Process.monitor(context.observer)
    timer = Process.send_after(self(), {context.nonce, :release}, context.hold_ms)
    started = System.monotonic_time(:millisecond)
    send(context.observer, {context.nonce, :held, self(), context.phase})

    try do
      receive do
        {nonce, :release} when nonce == context.nonce ->
          send(context.observer, {
            nonce,
            :released,
            self(),
            System.monotonic_time(:millisecond) - started
          })

        {:DOWN, ^monitor, :process, _observer, _reason} ->
          :ok
      after
        context.hold_ms + 2_000 -> :ok
      end
    after
      Process.cancel_timer(timer)
      Process.demonitor(monitor, [:flush])
    end
  end
end
