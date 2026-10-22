defmodule AgentExamples.Quicksort.Progress do
  @moduledoc "Publishes partition snapshots to the example UI through native Ash notifications."
  use Ash.Notifier

  @doc "Builds a pure directive publishing one partition's current status."
  def notification(topic, node) do
    %Aikido.Directives.Notify{
      notification: %Ash.Notifier.Notification{
        for: [__MODULE__],
        data: %{topic: topic, node: node}
      }
    }
  end

  @impl true
  def notify(%{data: %{topic: topic, node: node}}) do
    Phoenix.PubSub.broadcast(AgentExamples.PubSub, topic, {:quicksort_progress, topic, node})
  end
end
