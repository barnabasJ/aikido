defmodule Aikido.Ownership.Directives.MonitorParent do
  @moduledoc "Monitors one parent process and acknowledges the reference through a signal."
  use Aikido.Directive

  typed_struct do
    field :pid, :term do
      description "Logical parent process to monitor."
      allow_nil? false
    end
  end

  @impl true
  def exec(%{pid: pid}, signal, runtime) do
    ref = Process.monitor(pid)

    acknowledgement =
      Aikido.Ownership.Signals.ParentMonitored.new!(%{pid: pid, ref: ref},
        source: "/agent/#{runtime.id}"
      )
      |> Aikido.Signal.inherit(signal)

    Aikido.AgentServer.cast(self(), acknowledgement)
    :ok
  end
end
