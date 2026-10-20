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

  require Ash.Tracer

  @callback exec(struct(), Jido.Signal.t(), Aikido.AgentServer.State.t()) ::
              :ok | {:stop, term()}

  use Spark.Dsl, default_extensions: [extensions: [Ash.TypedStruct.Dsl]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @behaviour Aikido.Directive
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @type t :: %__MODULE__{}
    end
  end

  @doc """
  Complete a signal envelope during directive execution.

  Actions can return `%Jido.Signal{id: nil, type: type, data: data, source: source}`
  without generating IDs or reading the clock. Emit, Schedule and Cron supply
  that runtime metadata here. Fully constructed signals retain their identity.
  This function performs runtime work and must not be called from an action.
  """
  def materialize_signal(%Jido.Signal{id: id, time: time} = signal)
      when is_binary(id) and is_binary(time), do: signal

  def materialize_signal(%Jido.Signal{} = signal) do
    signal
    |> Map.from_struct()
    |> materialize_signal()
  end

  def materialize_signal(signal) when is_map(signal) do
    signal
    |> Map.reject(fn {key, value} -> key in [:id, :time, :source] && is_nil(value) end)
    |> Jido.Signal.new!()
  end

  @doc "Execute a directive through its module's behaviour callback."
  @spec exec(struct(), Jido.Signal.t(), Aikido.AgentServer.State.t()) ::
          :ok | {:stop, term()}
  def exec(%module{} = directive, signal, runtime) do
    tracers = Aikido.SignalCtx.tracers(signal, Map.get(runtime, :aikido))

    Ash.Tracer.span {:custom, :aikido_directive}, inspect(module), tracers do
      Ash.Tracer.set_metadata(tracers, {:custom, :aikido_directive}, %{
        signal_id: signal.id,
        signal_type: signal.type,
        agent_id: runtime.id
      })

      module.exec(directive, signal, runtime)
    end
  end
end
