defmodule Aikido.AiReact.TodoVerification do
  @moduledoc "Application-owned todo verification with model feedback and opaque continuation data."
  use Ash.Resource, data_layer: :embedded, domain: Aikido.RuntimeDomain

  code_interface do
    define :new, action: :create
  end

  actions do
    default_accept :*
    defaults [:read, :create]
  end

  attributes do
    attribute :accepted?, :boolean do
      description "Whether the application accepts the proposed answer and todo evidence."
      allow_nil? false
      public? true
    end

    attribute :feedback, :string do
      description "Optional corrective text shown to the model when verification rejects an answer."
      public? true
    end

    attribute :data, :term do
      description "Opaque application continuation data supplied only to the next verifier invocation."
      sensitive? true
      public? true
    end
  end
end
