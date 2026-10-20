defmodule Aikido.Agent do
  @moduledoc """
  An immutable container for agent identity and typed domain state.

  Native Ash actions return `Aikido.ActionResult` values. AgentServer supplies
  the current state, accepts successful state transitions and executes the
  returned directives. Actions are pure; all side effects belong in directives.

  ## Defining an Agent Module

  `use Aikido.Agent` creates an embedded Ash resource host. State schemas
  become attributes on that same resource.
  Reducers are native Ash actions implemented by separate callback modules.

  ```elixir
  defmodule MyAgent do
    use Aikido.Agent,
      middleware: [Aikido.Middlewares.Retry]

    agent do
      name "my_agent"
      description "My custom agent"
      path :domain
      schema do
        attribute :counter, :integer, default: 0
      end
    end

    slices do
      slice :memory, MyApp.MemorySlice
      slice :slack, MyApp.SlackSlice do
        options token: "xoxb-..."
      end
    end

    signal_routes do
      route "user.created", {MyApp.Users, :handle_created}
      route "payment.*", {MyApp.Payments, :handle_large}, priority: 10, match: &(&1.data.amount > 100)
    end

    schedules do
      schedule "*/5 * * * *", "tick.heartbeat"
    end
  end
  ```

  Each `slice :path, Module` line in `slices do … end` mounts a slice
  at the agent-declared path. Middleware modules appear in the top-level
  `middleware: […]` list, in their execution order.

  The `extensions: […]` keyword stays available for modules whose typed
  DSL section the host wants to call into (e.g. `extensions: [Aikido.Slices.AiReact]`
  unlocks `react do … end`). It is **not** the channel for slice
  enumeration — that role moves entirely into `slices do … end`.
  """

  defmacro __using__(opts) do
    {opts, _bindings} = Code.eval_quoted(opts, [], __CALLER__)

    quote do
      use Ash.Resource,
        data_layer: :embedded,
        validate_domain_inclusion?: false,
        extensions: unquote([Aikido.Dsl.Agent] ++ (opts[:extensions] || []))

      unquote(Aikido.Agent.handle_opts(opts))
    end
  end

  use Ash.TypedStruct

  typed_struct do
    field :id, :string, allow_nil?: false, default: &Aikido.Util.generate_id/0
    field :agent_module, :atom
    field :name, :string
    field :description, :string
    field :state, :map, allow_nil?: false, default: %{}
  end

  @type t :: %__MODULE__{}

  @doc """
  Returns signal routes for this agent.
  """
  @callback signal_routes(ctx :: map()) :: [Jido.Signal.Router.route_spec()]

  @doc """
  Optional persistence hooks.
  """
  @callback checkpoint(agent :: t(), ctx :: map()) :: {:ok, map()} | {:error, term()}
  @callback restore(checkpoint :: map(), ctx :: map()) :: {:ok, t()} | {:error, term()}

  @optional_callbacks [
    signal_routes: 1,
    checkpoint: 2,
    restore: 2
  ]

  @doc false
  def handle_opts(opts) do
    user_middleware =
      opts
      |> Keyword.get(:middleware, [])
      |> List.wrap()

    quote location: :keep do
      @behaviour Aikido.Agent

      @persist {:aikido_user_middleware, unquote(Macro.escape(user_middleware))}
      @persist {:aikido_instance_module, unquote(opts[:aikido])}
      @persist {:default_slices_override, unquote(Macro.escape(opts[:default_slices]))}
    end
  end
end
