defmodule Aikido.Signals.AiWorker.Accept do
  @moduledoc "Typed payload for `harness.task`."
  use Aikido.Signal

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

  signal do
    type "harness.task"

    schema do
      attribute :task_id, :string do
        description "Team-assigned task identifier used to correlate acceptance, cancellation and completion."
        allow_nil? false
      end

      attribute :member, :term do
        description "Team member identity to include in the correlated task result."
        allow_nil? false
      end

      attribute :attempt, :string do
        description "Team-member incarnation token used to reject results from an obsolete assignment."
        allow_nil? false
      end

      attribute :reply_to, :term do
        description "Assigning team process that receives the correlated task result."
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Application-owned workflow details retained with the task request."
        default %{}
      end

      attribute :text, :string do
        description "Work request passed to the worker's ReAct conversation."
        allow_nil? false
      end

      attribute :model, :term do
        description "Optional model override for this task; otherwise the worker's configured model is used."
      end

      attribute :client, :module do
        description "Optional generation callback module overriding the worker configuration."
      end

      attribute :tool_context, :map do
        description "Native Ash scope and application context for tools invoked by this task."
      end

      attribute :tools, {:array, :atom} do
        description "Optional native Ash AI tool names exposed while executing this task."
      end

      attribute :tool_options, {:array, :tuple} do
        description "Native Ash AI options used to prepare tools for this task."
        constraints @keyword_constraints
      end

      attribute :system_prompt, :string do
        description "Optional system instructions overriding the worker configuration for this task."
      end

      attribute :llm_opts, {:array, :tuple} do
        description "Provider generation options merged into this task's model requests."
        constraints @keyword_constraints
      end

      attribute :max_iterations, :integer do
        description "Optional maximum number of model turns allowed for this task."
        constraints min: 1
      end
    end
  end
end
