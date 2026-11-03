defmodule Aikido.AiReact.AttemptTiming.System do
  @moduledoc "System clocks and Process timers for production attempt execution."
  @behaviour Aikido.AiReact.AttemptTiming

  @impl true
  def monotonic_ms(_context), do: System.monotonic_time(:millisecond)
  @impl true
  def system_ms(_context), do: System.system_time(:millisecond)
  @impl true
  def schedule_at(context, target, tag, deadline) do
    Process.send_after(target, tag, max(0, deadline - monotonic_ms(context)))
  end

  @impl true
  def cancel_timer(_context, reference), do: Process.cancel_timer(reference)
  @impl true
  def control_timeout(_context, remaining), do: remaining
end
