defmodule Aikido.AiReact.Types.TodoVerificationResult do
  @moduledoc "Native union of an existing boolean verdict and application verification feedback/data."
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        boolean: [type: :boolean],
        verification: [type: Aikido.AiReact.TodoVerification]
      ]
    ]
end
