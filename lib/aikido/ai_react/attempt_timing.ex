defmodule Aikido.AiReact.AttemptTiming do
  @moduledoc """
  Per-call timing for cancellable I/O attempts.

  A trusted application can supply `{backend, private_context}` in the native
  call's `scope.context[:aikido_attempt_timing]`. LLMCall forwards it only to the
  transient attempt options. It is never an AI option, state attribute, provider
  option or checkpoint field. The default backend uses System and Process.

  A test backend controls both time reads and delivery of private deadline tags.
  `control_timeout/2` bounds actual subscribe/state transport calls separately
  from logical business deadlines. Production keeps the existing remaining
  budget; tests may use a bounded failure ceiling for those actual control calls.
  """
  @type context :: term()
  @type capability :: {module(), context()}

  @callback monotonic_ms(context()) :: integer()
  @callback system_ms(context()) :: integer()
  @callback schedule_at(context(), pid(), term(), integer()) :: reference()
  @callback cancel_timer(context(), reference()) :: term()
  @callback control_timeout(context(), non_neg_integer()) :: non_neg_integer()

  @schema [timing: [type: {:tuple, [:atom, :any]}, required: true]]

  @doc "Resolve one transient timing capability using native Spark option validation."
  def resolve(value) do
    Spark.Options.validate!([timing: value || {__MODULE__.System, nil}], @schema)[:timing]
  end

  def monotonic_ms({backend, context}), do: backend.monotonic_ms(context)
  def system_ms({backend, context}), do: backend.system_ms(context)

  def schedule_at({backend, context}, target, tag, deadline),
    do: backend.schedule_at(context, target, tag, deadline)

  def cancel_timer({backend, context}, reference), do: backend.cancel_timer(context, reference)

  def control_timeout({backend, context}, remaining),
    do: backend.control_timeout(context, remaining)
end
