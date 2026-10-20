defmodule Aikido.SignalCtx do
  @moduledoc """
  Per-signal runtime context helpers built on `Jido.Signal`'s `extensions` field.

  `signal.extensions[:aikido_ctx]` is the canonical location for runtime context
  (user, tenant, parent, partition, agent_id) that flows alongside a
  signal through middleware, actions, and emitted child directives.

  Native Ash tracer contexts travel separately in `:ash_tracer_context`.

  `Jido.Signal` lives in the `:jido_signal` dependency, so these helpers live
  here rather than on the struct itself.

  ## Example

      iex> sig = Jido.Signal.new!(%{type: "work.start", data: %{}})
      iex> sig = Aikido.SignalCtx.put(sig, :workflow_id, "step-1")
      iex> Aikido.SignalCtx.get(sig, :workflow_id)
      "step-1"
      iex> Aikido.SignalCtx.ctx(sig)
      %{workflow_id: "step-1"}
  """

  alias Jido.Signal

  @ctx_key :aikido_ctx

  @type ctx :: map()

  @doc """
  Returns the full ctx map carried on the signal (default `%{}`).
  """
  @spec ctx(Signal.t()) :: ctx()
  def ctx(%Signal{} = signal) do
    Map.get(extensions(signal), @ctx_key, %{})
  end

  @doc """
  Replaces the entire ctx on the signal.
  """
  @spec put_ctx(Signal.t(), ctx()) :: Signal.t()
  def put_ctx(%Signal{} = signal, %{} = new_ctx) do
    put_extensions(signal, Map.put(extensions(signal), @ctx_key, new_ctx))
  end

  @doc """
  Sets a single key in the signal's ctx, creating the ctx if missing.
  """
  @spec put(Signal.t(), atom(), term()) :: Signal.t()
  def put(%Signal{} = signal, key, value) when is_atom(key) do
    put_ctx(signal, Map.put(ctx(signal), key, value))
  end

  @doc """
  Reads a key from the signal's ctx.
  """
  @spec get(Signal.t(), atom(), term()) :: term()
  def get(%Signal{} = signal, key, default \\ nil) when is_atom(key) do
    Map.get(ctx(signal), key, default)
  end

  @doc """
  Merges `additions` into the signal's ctx (right-biased).
  """
  @spec merge(Signal.t(), map()) :: Signal.t()
  def merge(%Signal{} = signal, %{} = additions) do
    put_ctx(signal, Map.merge(ctx(signal), additions))
  end

  @doc """
  Removes a key from the signal's ctx.
  """
  @spec delete(Signal.t(), atom()) :: Signal.t()
  def delete(%Signal{} = signal, key) when is_atom(key) do
    put_ctx(signal, Map.delete(ctx(signal), key))
  end

  @doc """
  Copies ctx from `source` onto `target`. If `target` already has a ctx, the
  source ctx is merged into it (target keys win).
  """
  @spec inherit(Signal.t(), Signal.t()) :: Signal.t()
  def inherit(%Signal{} = target, %Signal{} = source) do
    src = ctx(source)
    dst = ctx(target)
    context = Map.merge(tracer_context(source), tracer_context(target))

    extensions = Map.put(extensions(target), @ctx_key, Map.merge(src, dst))

    extensions =
      if context == %{}, do: extensions, else: Map.put(extensions, :ash_tracer_context, context)

    target
    |> put_extensions(extensions)
    |> capture_tracing()
  end

  @doc "Ash tracers participating in this signal, including configured defaults."
  def tracers(signal, instance \\ nil) do
    Enum.uniq(
      List.wrap(get(signal, :tracer)) ++
        Map.keys(tracer_context(signal)) ++
        List.wrap(Aikido.Observe.Config.tracer(instance)) ++
        List.wrap(Application.get_env(:ash, :tracer))
    )
  end

  @doc "The opaque contexts captured by Ash for transfer to the receiving process."
  def tracer_context(%Signal{} = signal),
    do: Map.get(extensions(signal), :ash_tracer_context, %{})

  @doc "Capture native Ash span context before sending or scheduling a signal."
  def capture_tracing(%Signal{} = signal) do
    context = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers(signal))
    # Forwarded envelopes retain their parent when the forwarding process has
    # no active span. Effects executed in a span capture that newer parent.
    context = Map.reject(context, fn {_tracer, value} -> is_nil(value) end)
    context = Map.merge(tracer_context(signal), context)

    if context == %{},
      do: signal,
      else: put_extensions(signal, Map.put(extensions(signal), :ash_tracer_context, context))
  end

  @doc "Return the input signal's timestamp in milliseconds, or zero without an envelope."
  def timestamp(%Signal{time: time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 0
    end
  end

  def timestamp(_), do: 0

  defp extensions(%Signal{extensions: nil}), do: %{}
  defp extensions(%Signal{extensions: ext}) when is_map(ext), do: ext

  defp put_extensions(%Signal{} = signal, %{} = ext) do
    %{signal | extensions: ext}
  end
end
