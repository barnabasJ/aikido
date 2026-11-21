defmodule Aikido.AiReact.Types.ProviderParameterName do
  @moduledoc "Public ASCII parameter identifier, bounded to 64 bytes without trimming."
  use Ash.Type.NewType,
    subtype_of: :string,
    constraints: [
      min_length: 1,
      max_length: 64,
      length_count: :bytes,
      trim?: false,
      match: ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
    ]
end
