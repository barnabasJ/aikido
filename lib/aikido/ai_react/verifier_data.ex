defmodule Aikido.AiReact.VerifierData do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  actions do
    default_accept :*
    defaults [:create]
  end

  attributes do
    attribute :value, :term do
      description "Private verifier continuation data carried by an internal I/O directive."
      sensitive? true
      public? true
    end
  end
end
