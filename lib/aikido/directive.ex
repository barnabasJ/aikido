defmodule Aikido.Directive do
  @moduledoc """
  A typed I/O directive and its execution behaviour.

  Uses Spark with Ash's typed-struct DSL. Declare the descriptor's fields and
  implement `exec/3` in the same module. The host generates the struct's public
  `t()` type; Ash validates the declared field types and constraints.

      defmodule MyApp.Notify do
        use Aikido.Directive

        typed_struct do
          field :recipient, :term, allow_nil?: false
          field :message, :term
        end

        @impl true
        def exec(directive, _signal, _runtime) do
          send(directive.recipient, directive.message)
          :ok
        end
      end

  Side effects belong only in directives; actions are pure and return their
  next state and directive descriptors without executing any effects.
  Directives must not mutate domain or runtime state.

  Execution performs I/O only. Return `:ok` to continue or `{:stop, reason}` to
  stop the agent. State changes belong in actions; asynchronous results return
  as signals. Never wait for an agent reply inside a directive callback.
  """

  @callback exec(struct(), Jido.Signal.t(), Aikido.AgentServer.State.t()) ::
              :ok | {:stop, term()}

  use Spark.Dsl, default_extensions: [extensions: [Ash.TypedStruct.Dsl]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @behaviour Aikido.Directive

      @doc "Returns the directive's Ash type."
      def schema, do: __MODULE__
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @type t :: %__MODULE__{}
    end
  end

  @doc "Execute a directive through its module's behaviour callback."
  @spec exec(struct(), Jido.Signal.t(), Aikido.AgentServer.State.t()) ::
          :ok | {:stop, term()}
  def exec(%module{} = directive, signal, runtime), do: module.exec(directive, signal, runtime)
end
