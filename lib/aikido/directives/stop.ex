defmodule Aikido.Directives.Stop do
  @moduledoc """
  Request that the agent process stop.

  ## Fields

  - `reason` - Reason for stopping (default: `:normal`)
  """

  use Aikido.Directive

  typed_struct do
    field :reason, :term, allow_nil?: false, default: :normal, description: "Reason for stopping"
  end

  @type t :: %__MODULE__{}

  @impl true
  def exec(%{reason: reason}, _input_signal, _state) do
    {:stop, reason}
  end
end
