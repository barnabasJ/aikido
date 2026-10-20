defmodule Aikido.AgentServer.Actions.QueryChildren do
  @moduledoc """
  Implements the runtime's `:query_children` generic action.

  Returns a reply directive that projects children from runtime bookkeeping
  during execution, without changing domain state.
  """
  use Ash.Resource.Actions.Implementation

  alias Aikido.Signal.Call

  @impl true
  def run(input, _opts, _context) do
    directive =
      Call.reply_from_state(
        input.context.aikido.signal,
        "aikido.agent.query.children.reply",
        "aikido.agent.query.children.error",
        {__MODULE__, :build_reply, []}
      )

    Aikido.Types.ActionResult.new(
      state: %Aikido.Agent.SliceUpdate{slices: %{}},
      directives: List.wrap(directive)
    )
  end

  @doc false
  def build_reply(%Aikido.AgentServer.State{children: children}) do
    {:ok, %{children: Map.new(children, fn {tag, child} -> {tag, child.pid} end)}}
  end
end
