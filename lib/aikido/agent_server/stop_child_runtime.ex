defmodule Aikido.AgentServer.StopChildRuntime do
  @moduledoc false

  require Logger

  alias Aikido.AgentServer.State
  alias Jido.Signal

  @spec exec(term(), term(), Signal.t(), State.t()) :: :ok
  def exec(tag, reason, %Signal{} = input_signal, %State{} = state) do
    case State.get_child(state, tag) do
      nil ->
        Logger.debug("AgentServer #{state.id} cannot stop child #{inspect(tag)}: not found")
        :ok

      %{pid: pid} ->
        Logger.debug(
          "AgentServer #{state.id} stopping child #{inspect(tag)} with reason #{inspect(reason)}"
        )

        stop_signal =
          Signal.new!(
            "aikido.agent.stop",
            %{reason: normalize_stop_reason(reason)},
            source: "/agent/#{state.id}"
          )

        stop_signal = Aikido.SignalCtx.inherit(stop_signal, input_signal)

        _ = Aikido.AgentServer.cast(pid, stop_signal)

        :ok
    end
  end

  # Transient children only skip restart for OTP "clean" shutdown reasons.
  # Wrap custom reasons so StopChild removes the child instead of respawning it.
  defp normalize_stop_reason(:normal), do: :normal
  defp normalize_stop_reason(:shutdown), do: :shutdown
  defp normalize_stop_reason({:shutdown, _} = reason), do: reason
  defp normalize_stop_reason(reason), do: {:shutdown, reason}
end
