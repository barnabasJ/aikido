defmodule Aikido.Agent do
  @moduledoc """
  Immutable agent identity and typed state.

  Declare agents as Ash resources with `Aikido.Ash.Agent`. The convenience
  `use Aikido.Agent` installs that same extension and uses the shared runtime
  domain. Reducers are native generic actions returning `Aikido.ActionResult`;
  they are pure and return directives for all I/O.
  """

  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:extensions])
    extensions = [Aikido.Ash.Agent | Keyword.get(opts, :extensions, [])]

    quote do
      use Ash.Resource,
        domain: Aikido.RuntimeDomain,
        validate_domain_inclusion?: false,
        extensions: unquote(extensions)
    end
  end

  use Ash.TypedStruct

  typed_struct do
    field :id, :string, allow_nil?: false, default: &Ash.UUIDv7.generate/0
    field :agent_module, :atom
    field :name, :string
    field :description, :string
    field :state, :map, allow_nil?: false, default: %{}
  end

  @type t :: %__MODULE__{}

  @doc "Optional durable checkpoint serialization."
  @callback checkpoint(agent :: t(), ctx :: map()) :: {:ok, map()} | {:error, term()}
  @doc "Optional durable checkpoint restoration."
  @callback restore(checkpoint :: map(), ctx :: map()) :: {:ok, t()} | {:error, term()}
  @optional_callbacks checkpoint: 2, restore: 2
end
