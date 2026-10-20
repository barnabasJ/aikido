defmodule Aikido.Application do
  @moduledoc false
  use Application

  @doc false
  def start(_type, _args) do
    Aikido.Telemetry.setup()

    # Built-in dispatch extensions must be registered on a fresh VM, where their
    # compile-time registration callbacks have not run.
    Jido.Signal.Ext.Registry.register(Jido.Signal.Ext.Dispatch)

    Supervisor.start_link([], strategy: :one_for_one, name: Aikido.Supervisor)
  end
end
