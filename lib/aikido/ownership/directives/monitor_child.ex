defmodule Aikido.Ownership.Directives.MonitorChild do
  @moduledoc "Installs a process monitor and reports its reference through a signal."
  use Aikido.Directive

  typed_struct do
    field :tag, :term do
      description "Topology tag identifying the owned child."
      allow_nil? false
    end

    field :pid, :term do
      description "Child process to monitor."
      allow_nil? false
    end
  end

  @impl true
  def exec(%{tag: tag, pid: pid}, origin, runtime) do
    ref = Process.monitor(pid)

    signal =
      Aikido.Ownership.Signals.ChildMonitored.new!(%{tag: tag, pid: pid, ref: ref},
        source: "/agent/#{runtime.id}"
      )
      |> Aikido.Signal.inherit(origin)

    Aikido.AgentServer.cast(self(), signal)
    :ok
  end
end
