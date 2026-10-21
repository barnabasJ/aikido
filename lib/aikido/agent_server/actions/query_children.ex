defmodule Aikido.AgentServer.Actions.QueryChildren do
  @moduledoc """
  Pure reducer for the runtime's `:query_children` action.

  Reads reply routing from the current signal and returns an empty `SliceUpdate`
  with a reply directive. That directive projects child PIDs from live runtime
  bookkeeping during execution, leaving domain state unchanged.
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
      state: %Aikido.Types.SliceUpdate{slices: %{}},
      directives: List.wrap(directive)
    )
  end

  @doc false
  def build_reply(%Aikido.AgentServer.State{children: children}) do
    {:ok, %{children: Map.new(children, fn {tag, child} -> {tag, child.pid} end)}}
  end
end
