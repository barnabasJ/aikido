defmodule AikidoTest.GracefulCleanup.RecordActivation do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(changes: %{activations: state.activations + 1})
  end
end

defmodule AikidoTest.GracefulCleanup.RecordCleanup do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(changes: %{cleanups: state.cleanups + 1})
  end
end

defmodule AikidoTest.GracefulCleanup.RequestShutdown do
  use Aikido.Signal

  signal do
    type "cleanup.shutdown"
  end
end

defmodule AikidoTest.GracefulCleanup.Shutdown do
  use Ash.Resource.Actions.Implementation

  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(directives: [%Aikido.Directives.Stop{}])
  end
end

defmodule AikidoTest.GracefulCleanup.Agent do
  use Ash.Resource,
    domain: AikidoTest.GracefulCleanup.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "cleanup"

    schema do
      attribute :activations, :integer do
        description "Number of ready lifecycle transitions."
        default 0
        public? true
      end

      attribute :cleanups, :integer do
        description "Number of graceful cleanup transitions."
        default 0
        public? true
      end
    end

    route Aikido.AgentServer.Signals.LifecycleReady, AikidoTest.GracefulCleanup.RecordActivation,
      public?: false

    route Aikido.AgentServer.Signals.LifecycleStopping, AikidoTest.GracefulCleanup.RecordCleanup,
      public?: false

    route AikidoTest.GracefulCleanup.RequestShutdown, AikidoTest.GracefulCleanup.Shutdown,
      name: :shutdown
  end
end

defmodule AikidoTest.GracefulCleanup.Domain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :cleanup, AikidoTest.GracefulCleanup.Agent
  end
end

defmodule AikidoTest.GracefulCleanupTest do
  use AikidoTest.Case, async: false

  alias AikidoTest.GracefulCleanup.Domain
  alias AikidoTest.LifecycleWait

  setup do
    start_supervised!({Aikido, name: Aikido.Default, durable: AikidoTest.Case.durable_options()})
    :ok
  end

  test "domain stop persists the cleanup transition exactly once before restoration" do
    agent = Domain.cleanup_start!(%{})
    assert %{activations: 1, cleanups: 0} = Domain.cleanup_inspect!(agent)
    subscription = observe_cleanup(agent.pid)

    Domain.cleanup_stop!(agent)
    LifecycleWait.await_down(agent.pid)
    assert_single_cleanup(subscription)

    restored = Domain.cleanup_start!(%{id: agent.id})
    assert %{activations: 2, cleanups: 1} = Domain.cleanup_inspect!(restored)
  end

  test "a stop directive persists the cleanup transition exactly once" do
    agent = Domain.cleanup_start!(%{})
    subscription = observe_cleanup(agent.pid)
    Domain.cleanup_shutdown!(agent, %{})
    LifecycleWait.await_down(agent.pid)
    assert_single_cleanup(subscription)

    restored = Domain.cleanup_start!(%{id: agent.id})
    assert %{activations: 2, cleanups: 1} = Domain.cleanup_inspect!(restored)
  end

  test "crash recovery does not run graceful cleanup" do
    agent = Domain.cleanup_start!(%{})
    replacement = LifecycleWait.crash_and_await_replacement(agent.pid)
    assert %{cleanups: 0} = Domain.cleanup_inspect!(replacement)
  end

  defp observe_cleanup(pid) do
    {:ok, subscription} =
      Aikido.AgentServer.subscribe(pid, "aikido.agent.lifecycle.stopping", fn runtime ->
        {:ok, runtime.agent.state.state.cleanups}
      end)

    subscription
  end

  defp assert_single_cleanup(subscription) do
    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, 1}}}
    refute_received {:aikido_subscription, ^subscription, _}
  end
end
