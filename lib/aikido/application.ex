defmodule Aikido.Application do
  @moduledoc false
  use Application

  @doc false
  def start(_type, _args) do
    Aikido.Telemetry.setup()

    Supervisor.start_link([Aikido.Inspector.History.ActionTelemetry, Aikido.Inspector],
      strategy: :one_for_one,
      name: Aikido.Supervisor
    )
  end
end
