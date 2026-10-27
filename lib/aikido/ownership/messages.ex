defmodule Aikido.Ownership.Messages do
  @moduledoc "Translates owned-process exit messages into typed lifecycle signals."

  def from_down(runtime, ref, pid, reason) do
    case {Aikido.Ownership.parent(runtime), Aikido.Ownership.parent_monitor(runtime)} do
      {%{pid: ^pid} = parent, expected} when is_nil(expected) or expected == ref ->
        Aikido.Ownership.Signals.ParentDied.new!(
          %{former_parent: parent, reason: reason, monitor_ref: ref},
          source: "/agent/#{runtime.id}"
        )

      _ ->
        child_exit(runtime, ref, pid, reason)
    end
  end

  defp child_exit(runtime, ref, pid, reason) do
    Enum.find_value(Aikido.Ownership.children(runtime), fn
      {tag, %{pid: ^pid, ref: expected} = child} when is_nil(expected) or expected == ref ->
        Aikido.Ownership.Signals.ChildExit.new!(
          %{tag: tag, pid: pid, reason: reason, monitor_ref: ref, child_id: child.id},
          source: "/agent/#{runtime.id}"
        )

      _ ->
        nil
    end)
  end
end
