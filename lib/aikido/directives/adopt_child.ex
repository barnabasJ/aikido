defmodule Aikido.Directives.AdoptChild do
  @moduledoc """
  Attach an orphaned or unattached child agent to the current parent.

  This directive is the explicit reattachment path for Aikido's logical
  hierarchy. It updates the live child runtime so the child can resume
  parent-directed communication via `ctx.parent`.

  Adoption is explicit. Aikido does not automatically reconnect children
  when a logical parent restarts.

  Adoption updates the live runtime and the instance `Aikido.RuntimeStore`
  binding, so later child restarts rehydrate the adopted parent relationship.

  ## Fields

  - `child` - Child PID or child agent id to adopt
  - `tag` - Tag for tracking this adopted child
  - `meta` - Metadata to write into the child's new parent reference
  """

  use Ash.TypedStruct

  typed_struct do
    field :child, :term, allow_nil?: false, description: "Child PID or child id"
    field :tag, :term, allow_nil?: false, description: "Tag for tracking this adopted child"

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Metadata to pass to the adopted child"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for AdoptChild."
  @spec schema() :: Ash.Type.t()
  def schema, do: @schema
end
