defmodule Aikido.AiReact.Types.ModelTimeoutPhase do
  @moduledoc "Timeout phases reported by the SDK model owner and ReqLLM."
  use Ash.Type.Enum, values: [:attempt, :deadline, :connect, :receive, :total, :stream_idle]
end
