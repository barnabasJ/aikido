defmodule Aikido.AiReact.Types.StreamReceipt do
  @moduledoc "Identity of the latest adopted streaming batch; omitted from checkpoints."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        request_id: [type: :string, allow_nil?: false],
        iteration: [type: :integer, allow_nil?: false],
        attempt: [type: :integer, allow_nil?: false],
        sequence: [type: :integer, constraints: [min: 1], allow_nil?: false]
      ]
    ]
end
