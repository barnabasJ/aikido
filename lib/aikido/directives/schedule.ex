defmodule Aikido.Directives.Schedule do
  @moduledoc """
  Schedule a delayed message to the agent.

  The runtime will send the message back to the agent after the delay.

  ## Fields

  - `delay_ms` - Delay in milliseconds (must be >= 0)
  - `message` - Message to send after delay
  """

  use Ash.TypedStruct

  typed_struct do
    field :delay_ms, :integer,
      allow_nil?: false,
      description: "Delay in milliseconds",
      constraints: [min: 0]

    field :message, :term, allow_nil?: false, description: "Message to send after delay"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Schedule."
  @spec schema() :: Ash.Type.t()
  def schema, do: @schema
end
