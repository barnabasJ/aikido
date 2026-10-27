defmodule Aikido.Cron.Messages do
  @moduledoc "Translates scheduler monitor messages into typed signals for mounted cron slices."
  def from_down(runtime, ref, pid, reason) do
    Enum.find_value(runtime.agent.state, fn
      {_, %Aikido.Cron.Slice{monitors: monitors}} ->
        case Enum.find(monitors, fn {_id, monitor} -> monitor == ref end) do
          {id, _} ->
            Aikido.Cron.Signals.Died.new!(%{job_id: id, pid: pid, reason: reason},
              source: "/agent/#{runtime.id}/cron"
            )

          nil ->
            nil
        end

      _ ->
        nil
    end)
  end
end
