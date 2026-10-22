defmodule AgentExamples.Quicksort do
  @moduledoc "Recursive quicksort: each nonempty partition is a real, durable-hosted Aikido agent."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Agent.Extension]

  agent do
    name "quicksort"
    persistence :temporary

    schema do
      attribute :status, AgentExamples.Quicksort.Types.Status do
        description "Whether this partition is idle, waiting for children or sorted."
        default :idle
        allow_nil? false
        public? true
      end

      attribute :topic, :string do
        description "Application-owned PubSub topic for this sorting tree."
        default ""
      end

      attribute :branch, :string do
        description "Path through the partition tree; L and R identify child partitions."
        default "root"
      end

      attribute :numbers, {:array, :integer} do
        description "Values assigned to this partition."
        default []
      end

      attribute :pivot, :integer do
        description "Value separating the smaller and larger child partitions."
      end

      attribute :equal, {:array, :integer} do
        description "Values equal to the pivot, retained at this node."
        default []
      end

      attribute :partitions, :map do
        description "Smaller and larger unsorted lists dispatched when children become ready."
        default %{}
      end

      attribute :results, :map do
        description "Completed child partitions keyed by branch."
        default %{}
      end

      attribute :result, {:array, :integer} do
        description "Sorted values assembled from child results and the pivot."
        default []
        public? true
      end
    end

    route AgentExamples.Quicksort.Signals.Sort, AgentExamples.Quicksort.Actions.Partition

    route Aikido.AgentServer.Signals.ChildStarted, AgentExamples.Quicksort.Actions.StartChild,
      public?: false

    route AgentExamples.Quicksort.Signals.Sorted, AgentExamples.Quicksort.Actions.Combine,
      public?: false
  end
end
