defmodule Aikido.AgentServer.ParentRef do
  @moduledoc """
  Reference to a logical parent agent in Aikido hierarchy tracking.

  `ParentRef` models Aikido's logical parent-child relationship, which is layered
  on top of OTP supervision. Parent and child agents are still OTP peers under
  a supervisor; the parent relationship is represented explicitly with this
  struct, child-start signals, and process monitors.

  The current parent ref lives on `%Aikido.AgentServer.State{}` (under
  `:parent`) and is exposed to actions in `input.context.aikido.parent`. When a
  child becomes orphaned, the runtime moves the former parent to
  `state.orphaned_from` and emits identity-transition signals
  (`aikido.agent.identity.parent_died` / `aikido.agent.identity.orphaned`).
  """

  use Ash.TypedStruct

  typed_struct do
    field :pid, :term, allow_nil?: false, description: "Parent process PID"

    field :id, :string,
      allow_nil?: false,
      description: "Parent instance ID",
      constraints: [trim?: false, allow_empty?: true]

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition of the parent agent"

    field :tag, :term,
      allow_nil?: false,
      description: "Tag assigned by parent when spawning this child"

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Arbitrary metadata from parent"
  end

  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc """
  Creates a new ParentRef from a map of attributes.

  Returns `{:ok, parent_ref}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    super(attrs)
  end

  def new(_), do: {:error, Aikido.Error.validation_error("ParentRef requires a map")}

  @doc """
  Creates a new ParentRef from a map, raising on error.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, parent_ref} ->
        parent_ref

      {:error, reason} ->
        raise Aikido.Error.validation_error("Invalid ParentRef", details: reason)
    end
  end

  @doc """
  Validates that a value is a valid ParentRef.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = parent_ref), do: {:ok, parent_ref}
  def validate(attrs) when is_map(attrs), do: new(attrs)

  def validate(_),
    do: {:error, Aikido.Error.validation_error("Expected a ParentRef struct or map")}
end
