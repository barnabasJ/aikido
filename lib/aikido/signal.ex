defmodule Aikido.Signal do
  @moduledoc """
  An internal signal envelope carrying arbitrary data and native Ash caller scope.

  Native `new/1` and Ash type casting validate envelopes without generating
  identity or time. Pure actions can use these constructors or return literals.
  `materialize/1`, `new/2`, and `new/3` supply runtime metadata at I/O boundaries.
  Typed definitions use `use Aikido.Signal` with the `signal` and `schema` Spark DSL.

  Pass `scope: signal` to native Ash actions to reuse its resolved caller scope,
  including ordinary application context. Use `Ash.Scope.to_opts(signal)` when
  forwarding tracer options as well; native generic action scope extraction
  currently omits the tracer getter. At a new process boundary, restore captured
  span ancestry with
  `Ash.ProcessHelpers.transfer_context(Aikido.Signal.tracer_context(signal))`
  before invoking the action. Scope extraction includes the captured tracers;
  restoring their process-local span context remains an I/O boundary operation.
  """
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Signal identity used for correlation and processing receipts."
    end

    field :time, :string do
      description "UTC timestamp recorded when the signal is materialized at an I/O boundary."
    end

    field :type, :string do
      description "Concrete event type matched against the receiving agent's routes."
      allow_nil? false
      constraints trim?: false
    end

    field :source, :string do
      description "Origin identifier attached by the component that emits the signal."
      allow_nil? false
      default "/aikido"
      constraints trim?: false
    end

    field :subject, :string do
      description "Optional subject or originating request identity used to correlate replies."
      constraints trim?: false, allow_empty?: true
    end

    field :data, :term do
      description "Payload delivered to the routed action, including arbitrary native terms."
    end

    field :scope, :map do
      description "Native Ash actor, tenant, authorization and application context carried with the signal."
      allow_nil? false
      default %{}
    end

    field :tracer_context, :map do
      description "Native Ash tracer span context transferred across process boundaries."
      allow_nil? false
      default %{}
    end

    field :reply_to, :term do
      description "Destination used by request/reply directives to return a correlated response."
    end
  end

  @type t :: %__MODULE__{}

  defmacro __using__(opts) do
    quote do
      use Aikido.Signal.Definition, unquote(opts)
    end
  end

  @doc "Validate an envelope and supply missing identity and timestamp at an I/O boundary."
  def materialize(%__MODULE__{} = signal),
    do: signal |> Map.from_struct() |> materialize()

  def materialize(attrs) do
    attrs = Map.new(attrs)

    attrs =
      Enum.reduce([:id, :time], attrs, fn key, attrs ->
        if is_nil(Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))) do
          value =
            if key == :id,
              do: Ash.UUIDv7.generate(),
              else: DateTime.to_iso8601(DateTime.utc_now())

          Map.put(attrs, key, value)
        else
          attrs
        end
      end)

    new(attrs)
  end

  @doc "Construct and materialize an internal signal with arbitrary data at an I/O boundary."
  def new(type, data, opts \\ []),
    do: materialize(Map.merge(Map.new(opts), %{type: type, data: data}))

  @doc "Construct a signal, raising on invalid envelope fields."
  def new!(type, data, opts \\ []), do: new(type, data, opts) |> Ash.Helpers.unwrap_or_raise!()

  @doc false
  def from_definition(module, data, opts) do
    with {:ok, cast} <- Ash.Type.cast_input(module, data, []) do
      opts = Map.put_new(Map.new(opts), :source, Aikido.Signal.Info.signal_source!(module))
      new(Aikido.Signal.Info.signal_type!(module), cast, opts)
    else
      {:error, errors} -> {:error, Ash.Error.to_error_class(errors)}
      :error -> {:error, Ash.Error.to_error_class("Signal definition data must be a map")}
    end
  end

  @doc "The native caller scope carried alongside this signal."
  def ctx(%__MODULE__{scope: scope}), do: scope

  @doc "Replace the native caller scope without materializing an envelope."
  def put_ctx(%__MODULE__{} = signal, %{} = scope), do: %{signal | scope: scope}

  @doc "Set one caller scope value."
  def put(%__MODULE__{} = signal, key, value),
    do: put_ctx(signal, Map.put(ctx(signal), key, value))

  @doc "Read one caller scope value."
  def get(%__MODULE__{} = signal, key, default \\ nil), do: Map.get(ctx(signal), key, default)

  @doc "Merge caller scope values, with additions taking precedence."
  def merge(%__MODULE__{} = signal, values), do: put_ctx(signal, Map.merge(ctx(signal), values))

  @doc "Delete one caller scope value."
  def delete(%__MODULE__{} = signal, key), do: put_ctx(signal, Map.delete(ctx(signal), key))

  @doc "Inherit scope and trace ancestry; explicit target values take precedence."
  def inherit(%__MODULE__{} = target, %__MODULE__{} = source) do
    %{
      target
      | scope: Map.merge(ctx(source), ctx(target)),
        tracer_context: Map.merge(tracer_context(source), tracer_context(target))
    }
    |> capture_tracing()
  end

  @doc "Ash tracers participating in this signal, including runtime defaults."
  def tracers(signal, instance \\ nil) do
    Enum.uniq(
      List.wrap(get(signal, :tracer)) ++
        Map.keys(tracer_context(signal)) ++
        List.wrap(Aikido.Telemetry.Config.tracer(instance)) ++
        List.wrap(Application.get_env(:ash, :tracer))
    )
  end

  @doc "Opaque native Ash trace contexts for transfer to another process."
  def tracer_context(%__MODULE__{tracer_context: context}), do: context

  @doc "Capture current native Ash span ancestry before delivering a signal."
  def capture_tracing(%__MODULE__{} = signal) do
    context = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers(signal))
    context = Map.reject(context, fn {_tracer, value} -> is_nil(value) end)
    %{signal | tracer_context: Map.merge(tracer_context(signal), context)}
  end

  @doc "The envelope timestamp in milliseconds, or zero when no timestamp exists."
  def timestamp(%__MODULE__{time: time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 0
    end
  end

  def timestamp(_), do: 0
end

defimpl Ash.Scope.ToOpts, for: Aikido.Signal do
  def get_actor(%{scope: scope}), do: Map.fetch(scope, :actor)
  def get_tenant(%{scope: scope}), do: Map.fetch(scope, :tenant)
  def get_context(%{scope: scope}), do: Map.fetch(scope, :context)
  def get_authorize?(%{scope: scope}), do: Map.fetch(scope, :authorize?)

  def get_tracer(%{scope: scope, tracer_context: tracer_context}) do
    case {Map.fetch(scope, :tracer), Map.keys(tracer_context)} do
      {:error, []} -> :error
      {{:ok, tracer}, []} -> {:ok, tracer}
      {configured, captured} -> {:ok, Enum.uniq(tracers(configured) ++ captured)}
    end
  end

  defp tracers({:ok, tracer}), do: List.wrap(tracer)
  defp tracers(:error), do: []
end
