defmodule AgentExamples.Quicksort.RunHistory do
  @moduledoc "Session-owned display summaries survive LiveView reconnects independently of live sorting agents."
  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def topic(root_id), do: "quicksort:" <> root_id

  def open(topic),
    do: Agent.update(__MODULE__, &Map.put(&1, topic, AgentExamples.Quicksort.TreeView.new()))

  def fetch(topic), do: Agent.get(__MODULE__, &Map.fetch(&1, topic))
  def close(topic), do: Agent.update(__MODULE__, &Map.delete(&1, topic))

  def record(topic, node) do
    Agent.cast(__MODULE__, fn histories ->
      case Map.fetch(histories, topic) do
        {:ok, tree} ->
          Map.put(histories, topic, AgentExamples.Quicksort.TreeView.put_node(tree, node))

        :error ->
          histories
      end
    end)
  end
end
