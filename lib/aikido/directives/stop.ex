defmodule Aikido.Directives.Stop do
  @moduledoc """
  Request that the agent process stop.

  ## Fields

  - `reason` - Reason for stopping (default: `:normal`)
  """

  use Ash.TypedStruct

  typed_struct do
    field :reason, :term, allow_nil?: false, default: :normal, description: "Reason for stopping"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Stop."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema
end
