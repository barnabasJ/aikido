defmodule Aikido.Team.Types.CoordinationTask do
  @moduledoc "A task visible to its requesting principal without private dispatch configuration."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Native task correlation identifier."
      allow_nil? false
    end

    field :member, :term do
      description "Authored member assigned the task."
      allow_nil? false
    end

    field :requester, :term do
      description "Member that requested this task, or the explicit coordinator :self."
      allow_nil? false
    end

    field :notify, :term do
      description "Authored member designated to receive this task's result."
    end

    field :status, Aikido.Team.Types.CoordinationTaskStatus do
      description "Current assignment or settlement state."
      allow_nil? false
    end

    field :result, :term do
      description "Application-authored result exposed only to the requesting principal."
    end

    field :metadata, :map do
      description "Only the required Todo identifier and explicitly authored public metadata."
      constraints fields: [required_todo: [type: :string], public: [type: :map]]
      default %{}
      allow_nil? false
    end
  end
end
