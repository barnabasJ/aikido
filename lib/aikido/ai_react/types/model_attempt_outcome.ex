defmodule Aikido.AiReact.Types.ModelAttemptOutcome do
  @moduledoc "Result of an observed SDK model attempt."
  use Ash.Type.Enum, values: [:completed, :failed, :cancelled]
end
