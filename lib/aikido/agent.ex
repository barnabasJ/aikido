defmodule Aikido.Agent do
  @moduledoc """
  Immutable agent identity and typed state.

  Declare agents as Ash resources with `Aikido.Ash.Agent`. The convenience
  `use Aikido.Agent` merges that extension into native `Ash.Resource` options.
  Pass `domain: MyApp.Agents` for your application's domain. The shared runtime
  domain is the default; ordinary Ash domain-inclusion validation stays enabled.

  Reducers are native generic actions returning `Aikido.Types.ActionResult`.
  They are pure and return directives for all I/O.
  """

  defmacro __using__(opts) do
    opts =
      opts
      |> Keyword.put_new(:domain, Aikido.RuntimeDomain)
      |> Keyword.update(:extensions, [Aikido.Ash.Agent], &[Aikido.Ash.Agent | &1])

    quote do
      use Ash.Resource, unquote(opts)
    end
  end

  use Ash.TypedStruct

  typed_struct do
    field :id, :string, allow_nil?: false
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
