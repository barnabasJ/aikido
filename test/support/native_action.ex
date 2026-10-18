defmodule AikidoTest.NativeAction do
  @moduledoc false

  def run(reference, signal, state, options, context) do
    Aikido.Exec.run(
      reference,
      signal.data || %{},
      %{signal: signal, state: state, action_opts: options, ctx: context},
      timeout: 0,
      telemetry: :silent
    )
  end
end
