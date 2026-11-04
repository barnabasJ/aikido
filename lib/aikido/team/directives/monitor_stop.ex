defmodule Aikido.Team.Directives.MonitorStop do
  @moduledoc "Installs one tagged stop-target monitor and reports its native reference."
  use Aikido.Directive

  typed_struct do
    field :target, :term do
      description "Exact process incarnation selected by the current stop step."
      allow_nil? false
    end

    field :member, :term do
      description "Topology member selected by the current stop step."
      allow_nil? false
    end

    field :operation_id, :string do
      description "Existing lifecycle operation owning this monitor."
      allow_nil? false
    end
  end

  @impl true
  def exec(directive, input, runtime) do
    tag = {:aikido_team_stop, directive.operation_id, directive.member}
    ref = :erlang.monitor(:process, directive.target, [{:tag, tag}])

    signal =
      Aikido.Team.Signals.StopMonitored.new!(%{
        operation_id: directive.operation_id,
        member: directive.member,
        pid: directive.target,
        ref: ref
      })
      |> Aikido.Signal.inherit(input)

    Aikido.Signal.Delivery.send(Aikido.Team.Delivery, self(), signal, runtime, %{
      kind: :stop_monitor
    })
  end
end
