defmodule Aikido.Directives.Error do
  @moduledoc """
  Signal an error from agent command processing.

  This directive carries a `Aikido.Error.t()` for consistent error handling.
  The runtime can log, emit, or handle errors based on this directive.

  ## Fields

  - `error` - A `Aikido.Error.t()` struct
  - `context` - Optional atom describing error context (e.g., `:normalize`, `:instruction`)
  """

  use Ash.TypedStruct

  typed_struct do
    field :error, :term, allow_nil?: false, description: "Aikido.Error struct"
    field :context, :atom, allow_nil?: true, description: "Error context"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Error."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema
end
