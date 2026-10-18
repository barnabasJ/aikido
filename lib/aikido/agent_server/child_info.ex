defmodule Aikido.AgentServer.ChildInfo do
  @moduledoc """
  Information about a child agent in the logical hierarchy.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice.

  Used for parent agents to track spawned children.
  """

  use Ash.TypedStruct

  typed_struct do
    field :pid, :term, allow_nil?: false, description: "Child process PID"
    field :ref, :term, allow_nil?: false, description: "Monitor reference for the child process"
    field :module, :atom, allow_nil?: false, description: "Child agent module"

    field :id, :string,
      allow_nil?: false,
      description: "Child instance ID",
      constraints: [trim?: false, allow_empty?: true]

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition of the child agent"

    field :tag, :term, allow_nil?: true, description: "Tag used when spawning"

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Metadata passed during spawn"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc false
  @spec schema() :: Ash.Type.t()
  def schema, do: @schema

  @doc """
  Creates a new ChildInfo from a map of attributes.

  Returns `{:ok, child_info}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    super(attrs)
  end

  def new(_), do: {:error, Aikido.Error.validation_error("ChildInfo requires a map")}

  @doc """
  Creates a new ChildInfo from a map, raising on error.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, child_info} ->
        child_info

      {:error, reason} ->
        raise Aikido.Error.validation_error("Invalid ChildInfo", details: reason)
    end
  end
end
