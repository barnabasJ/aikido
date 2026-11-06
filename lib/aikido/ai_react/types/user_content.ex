defmodule Aikido.AiReact.Types.UserContent do
  @moduledoc """
  Native term storage for one queued user input, retaining old embedded text.

  New dumps and term loads use Ash's term type. Older typed snapshots stored
  queue elements as raw strings; their UTF-8 text loads through Ash's string
  type. The external-term version byte 131 cannot begin valid UTF-8 text.

  Legacy non-UTF-8 binaries beginning with byte 131 are not supported as text:
  they take the native term decoder path and invalid terms fail. There is no
  rescue that turns a damaged term into text. This adapter cannot distinguish
  arbitrary old binary values that happen to be valid external terms.

  Keep the legacy string branch until all supported retained snapshots and
  restorable backups have been rewritten, or their format support is explicitly
  retired. It applies only to the AI queue and opening-input attributes.
  """
  use Ash.Type.NewType, subtype_of: :term

  @impl Ash.Type
  def cast_from_embedded(<<131, _::binary>> = value, constraints),
    do: super(value, constraints)

  def cast_from_embedded(value, _constraints) when is_binary(value),
    do: Ash.Type.cast_from_embedded(:string, value)

  def cast_from_embedded(value, constraints), do: super(value, constraints)
end
