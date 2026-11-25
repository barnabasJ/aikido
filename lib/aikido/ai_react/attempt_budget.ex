defmodule Aikido.AiReact.AttemptBudget do
  @moduledoc "A supervising attempt's immutable cutoff, captured before task scheduling or observation."
  use Ash.TypedStruct

  typed_struct do
    field :monotonic_deadline, :integer do
      description "Fixed supervising cutoff in the supplied clock's monotonic milliseconds."
      allow_nil? false
    end

    field :timeout_ms, :integer do
      description "Attempt budget remaining when the supervisor established this cutoff."
      allow_nil? false
      constraints min: 1
    end

    field :absolute_deadline_at, :integer do
      description "Effective Unix-millisecond attempt cutoff, captured before scheduling and capped by the inherited deadline."
      allow_nil? false
      constraints min: 1
    end

    field :deadline_at, :integer do
      description "Inherited absolute Unix-millisecond deadline, when supplied by the caller."
      constraints min: 1
    end
  end
end
