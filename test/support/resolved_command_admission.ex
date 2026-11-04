defmodule Aikido.ResolvedCommandAdmissionTest.TargetVisible do
  @moduledoc "Native application policy that can pause an ID check before command implementation resolves it."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "the exact live target permits this read or stop"

  @impl true
  def match?(actor, %{subject: input}, _options) do
    if input.action.name in [:inspect, :stop] do
      with {:ok, {_id, pid}} <-
             Aikido.Agent.CommandRuntime.resolve(input.resource, input.arguments.agent),
           {:ok, visible?} <- Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.visible?}) do
        observe_and_pause(input, actor, pid, visible?)
        visible?
      else
        _ -> false
      end
    else
      true
    end
  end

  defp observe_and_pause(input, actor, pid, visible?) do
    shared = input.context[:shared] || %{}
    observer = shared[:observer]
    pinned? = is_pid(input.arguments.agent)

    if observer do
      send(
        observer,
        {:command_target_checked, input.action.name, pinned?, pid, actor, input.tenant,
         shared[:marker]}
      )

      send(
        observer,
        {:command_policy_tracers, input.action.name, pinned?, pid,
         List.wrap(get_in(input.context, [:private, :tracer]))}
      )
    end

    if observer && shared[:pause_id_check?] && !pinned? && visible? do
      send(observer, {:command_id_check_waiting, self(), pid})

      receive do
        :continue_command_id_check -> :ok
      after
        5_000 -> raise "The test did not release its native command authorization check"
      end
    end
  end
end

defmodule Aikido.ResolvedCommandAdmissionTest.Agent do
  @moduledoc "A real temporary agent whose replacement can have different live read/stop permission."
  use Ash.Resource,
    domain: Aikido.ResolvedCommandAdmissionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension]

  agent do
    name "resolved_admission"
    instance Aikido.ResolvedCommandAdmissionTest.Instance
    persistence :temporary

    schema do
      attribute :visible?, :boolean do
        description "Current application permission read by native command policies."
        default true
        allow_nil? false
      end

      attribute :label, :string do
        description "Live value proving which incarnation the inspect command returns."
        allow_nil? false
      end
    end
  end

  policies do
    policy always() do
      authorize_if Aikido.ResolvedCommandAdmissionTest.TargetVisible
    end
  end
end

defmodule Aikido.ResolvedCommandAdmissionTest.Domain do
  @moduledoc "Native generated command interfaces used by resolved-target admission regressions."
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :subject, Aikido.ResolvedCommandAdmissionTest.Agent
  end
end
