defmodule Aikido.AiWorker.Types.RequestFailure do
  @moduledoc "Finite public classification of a rejected worker AI request."
  use Ash.Type.Enum, values: [:forbidden, :invalid, :runtime]
end
