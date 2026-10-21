defmodule Aikido.Agent do
  @moduledoc """
  Immutable agent identity and typed state.

  Declare agents as Ash resources with `Aikido.Agent.Extension`. The convenience
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
      |> Keyword.update(:extensions, [Aikido.Agent.Extension], &[Aikido.Agent.Extension | &1])

    quote do
      use Ash.Resource, unquote(opts)
    end
  end

  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Stable identity used to address and persist this agent."
      allow_nil? false
    end

    field :agent_module, :atom do
      description "Ash resource that defines this agent's state schema and routed actions."
    end

    field :name, :string do
      description "Human-readable name declared by the owning agent resource."
    end

    field :description, :string do
      description "Description of the agent's role from its resource configuration."
    end

    field :state, :map do
      description "Domain state keyed by the agent's own path and its mounted slice paths."
      allow_nil? false
      default %{}
    end
  end

  @type t :: %__MODULE__{}

  @doc "Optional durable checkpoint serialization."
  @callback checkpoint(agent :: t(), ctx :: map()) :: {:ok, map()} | {:error, term()}
  @doc "Optional durable checkpoint restoration."
  @callback restore(checkpoint :: map(), ctx :: map()) :: {:ok, t()} | {:error, term()}
  @optional_callbacks checkpoint: 2, restore: 2
end
