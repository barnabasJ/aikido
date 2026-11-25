defmodule Aikido.AiReact.Types.ModelAttemptPhase do
  @moduledoc "Observable stages of the single SDK model retry owner."
  use Ash.Type.Enum,
    values: [:started, :wire, :cleanup, :ended, :backoff, :provider_backoff, :terminal]
end
