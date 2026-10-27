defmodule Aikido.AiReact.Types.CompletionMode do
  @moduledoc "The condition that permits a ReAct run to complete."
  use Ash.Type.Enum,
    values: [
      model: "Complete when the model returns its answer.",
      todos: "Require all blocking todos to complete.",
      tasks: "Wait for this team's background assignments before completing its answer."
    ]
end
