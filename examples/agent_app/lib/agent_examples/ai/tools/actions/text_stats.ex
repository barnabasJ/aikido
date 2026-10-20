defmodule AgentExamples.AI.Tools.Actions.TextStats do
  @moduledoc "Counts words and characters in the supplied text."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    text = input.arguments.text
    {:ok, %{words: length(String.split(text)), characters: String.length(text)}}
  end
end
