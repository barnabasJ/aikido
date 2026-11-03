defmodule AikidoTest.SignalAdmissionTest.Choose do
  use Aikido.Signal

  signal do
    type "admission.choose"

    schema do
      attribute :blocked, :boolean do
        description "Select the denied branch instead of the permitted branch."
        default false
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.SignalAdmissionTest.Accept do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end

defmodule AikidoTest.SignalAdmissionTest.Block do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end

defmodule AikidoTest.SignalAdmissionTest.Mounted do
  use Aikido.Slice

  slice do
    name "admission_mounted"
    route "admission.mounted.first", :shared
    route "admission.mounted.second", :shared

    route "admission.mounted.predicate", :shared, match: fn _signal -> false end

    route "admission.mounted.predicate", :shared, match: fn _signal -> true end
  end

  actions do
    action :shared, Aikido.Types.ActionResult do
      argument :state, :term do
        description "Mounted slice state supplied by the runtime."
      end

      run AikidoTest.SignalAdmissionTest.Block
    end
  end
end

defmodule AikidoTest.SignalAdmissionTest.OtherMounted do
  use Aikido.Slice

  slice do
    name "admission_other_mounted"
    route "admission.other.shared", :shared
  end

  actions do
    action :shared, Aikido.Types.ActionResult do
      argument :state, :term do
        description "Mounted slice state supplied by the runtime."
      end

      run AikidoTest.SignalAdmissionTest.Block
    end
  end
end

defmodule AikidoTest.SignalAdmissionTest.Agent do
  use Aikido.Agent,
    domain: AikidoTest.SignalAdmissionTest.Domain,
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "admission_agent"
    slice :mounted, AikidoTest.SignalAdmissionTest.Mounted
    slice :other_mounted, AikidoTest.SignalAdmissionTest.OtherMounted

    route "admission.mounted.first", {AikidoTest.SignalAdmissionTest.Mounted, :shared}

    route "admission.other.shared", {AikidoTest.SignalAdmissionTest.OtherMounted, :shared},
      name: :other_shared

    route AikidoTest.SignalAdmissionTest.Choose, :accept,
      name: :accept,
      match: fn signal -> !signal.data.blocked end

    route AikidoTest.SignalAdmissionTest.Choose, :block,
      name: :block,
      match: fn signal -> signal.data.blocked end
  end

  actions do
    action :accept, Aikido.Types.ActionResult do
      argument :state, :term do
        description "Current agent state."
      end

      argument :blocked, :boolean do
        description "Select the permitted or denied conditional route."
        default false
      end

      run AikidoTest.SignalAdmissionTest.Accept
    end

    action :block, Aikido.Types.ActionResult do
      argument :state, :term do
        description "Current agent state."
      end

      argument :blocked, :boolean do
        description "Select the permitted or denied conditional route."
        default false
      end

      run AikidoTest.SignalAdmissionTest.Block
    end
  end

  policies do
    policy action([:block, :shared, :other_shared]) do
      forbid_if always()
    end

    policy always() do
      authorize_if always()
    end
  end
end

defmodule AikidoTest.SignalAdmissionTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :admission, AikidoTest.SignalAdmissionTest.Agent
  end
end

defmodule AikidoTest.SignalAdmissionTest do
  use AikidoTest.Case, async: false
  alias AikidoTest.SignalAdmissionTest.{Choose, Domain}

  setup do
    start_supervised!({Aikido, name: Aikido.Default, durable: durable_options()})
    agent = Domain.admission_start!(%{})
    :ok = Aikido.AgentServer.await_ready(agent.pid)
    {:ok, agent: agent}
  end

  test "an unmatched denied route does not block its permitted peer", %{agent: agent} do
    assert {:ok, _receipt} =
             Aikido.AgentServer.call(
               agent.pid,
               Choose.new!(%{blocked: false}),
               &{:ok, &1.agent.state}
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(
               agent.pid,
               Choose.new!(%{blocked: true}),
               &{:ok, &1.agent.state}
             )
  end

  test "all mounted spellings and predicates check their canonical public policy", %{agent: agent} do
    for type <- [
          "admission.mounted.first",
          "admission.mounted.second",
          "admission.mounted.predicate",
          "admission.other.shared"
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Aikido.AgentServer.call(
                 agent.pid,
                 Aikido.Signal.new!(type, %{}),
                 &{:ok, &1.agent.state}
               )
    end
  end
end
