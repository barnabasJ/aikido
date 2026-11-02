defmodule AgentExamples.InteractiveAssistant.PlaygroundOwner do
  @moduledoc "Requires an identified browser actor in the playground tenant."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the actor identifies a browser in the playground tenant"

  @impl true
  def match?(%{id: id}, %{subject: %{tenant: "playground"}}, _opts) when is_binary(id), do: true
  def match?(_actor, _context, _opts), do: false
end
