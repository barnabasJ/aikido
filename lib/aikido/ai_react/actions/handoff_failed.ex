defmodule Aikido.AiReact.Actions.HandoffFailed do
  @moduledoc "Fails a matching pending context handoff and plans failure hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Handoff, Hooks, Preparation}

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> reduce(Map.delete(input.arguments, :state))
    |> Preparation.finish(input)
  end

  @doc false
  def reduce(state, data) do
    if Handoff.active?(state, data) do
      state =
        Map.merge(state, %{
          status: :failed,
          error: {:context_handoff_failed, data.reason},
          handoff_pending: nil,
          hooks_pending: %{}
        })

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
