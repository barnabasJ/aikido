defmodule Aikido.AiReact.Types.ModelRequest do
  @moduledoc "Transient prepared model and provider options; never adopted into AI state."
  use Ash.TypedStruct

  typed_struct do
    field :model, :term do
      description "Model identifier or provider configuration used for this attempt only."
      allow_nil? false
    end

    field :options, {:array, :tuple} do
      description "Native generation keyword options, including transient provider credentials when supplied by preparation."
      allow_nil? false
      constraints items: [fields: [key: [type: :atom], value: [type: :term]]]
    end
  end
end
