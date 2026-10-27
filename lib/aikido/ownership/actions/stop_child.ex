defmodule Aikido.Ownership.Actions.StopChild do
  @moduledoc "Sends a graceful stop to the process currently bound to the requested child tag."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state

    directives =
      case Map.get(state.children, input.arguments.tag) do
        %{pid: pid} ->
          [
            %Aikido.Directives.Emit{
              target: pid,
              signal: %Aikido.Signal{
                type: "aikido.agent.stop",
                data: %{reason: shutdown_reason(input.arguments.reason)}
              }
            }
          ]

        nil ->
          []
      end

    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end

  defp shutdown_reason(:normal), do: :normal
  defp shutdown_reason(:shutdown), do: :shutdown
  defp shutdown_reason({:shutdown, _} = reason), do: reason
  defp shutdown_reason(reason), do: {:shutdown, reason}
end
