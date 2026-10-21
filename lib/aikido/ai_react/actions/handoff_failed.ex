defmodule Aikido.AiReact.Actions.HandoffFailed do
  @moduledoc "Fails a matching pending context handoff and plans failure hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Handoff, Hooks}

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> fail_pending_handoff(Map.delete(input.arguments, :state))
  end

  @doc false
  def fail_pending_handoff(state, data) do
    if Handoff.active?(state, data) do
      state =
        Map.merge(state, %{
          status: :failed,
          error: {:context_handoff_failed, data.reason},
          handoff_pending: nil,
          hooks_pending: %{}
        })
        |> Aikido.AiReact.Run.clear_tools_and_handoff()

      Hooks.transition(
        Aikido.Types.ActionResult.new(state: state),
        :run_failed,
        %{
          reason: state.error
        }
      )
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
