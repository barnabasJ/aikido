defmodule Aikido.Ownership.Actions.ReplyChildren do
  @moduledoc "Replies with the live children recorded in this ownership slice."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    children =
      Map.new(Aikido.Ownership.children(input.context.aikido), fn {tag, child} ->
        {tag, child.pid}
      end)

    directive =
      Aikido.Signal.Call.reply(
        input.context.aikido.signal,
        "aikido.agent.query.children.reply",
        %{children: children}
      )

    Aikido.Types.ActionResult.new(changes: nil, directives: List.wrap(directive))
  end
end
