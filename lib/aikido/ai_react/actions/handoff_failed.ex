defmodule Aikido.AiReact.Actions.HandoffFailed do
  @moduledoc "Fails a matching pending context handoff and plans failure hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{ConversationHandoff, HookQueue}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_handoff_failure(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp process_handoff_failure(input) do
    input.arguments.state
    |> fail_pending_handoff(Map.delete(input.arguments, :state))
  end

  @doc false
  def fail_pending_handoff(state, data) do
    if ConversationHandoff.active?(state, data) do
      state =
        Map.merge(state, %{
          status: :failed,
          error: {:context_handoff_failed, data.reason},
          handoff_pending: nil,
          hooks_pending: %{}
        })
        |> Aikido.AiReact.RunState.clear_tools_and_handoff()

      HookQueue.queue_event_hooks(
        {:ok, state, []},
        :run_failed,
        %{
          reason: state.error
        }
      )
    else
      {:ok, state, []}
    end
  end
end
