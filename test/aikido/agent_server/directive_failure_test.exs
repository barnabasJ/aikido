defmodule AikidoTest.DirectiveFailure.Signal do
  use Aikido.Signal

  signal do
    type "test.directive_failure"

    schema do
      attribute :target, :term do
        description "Process that observes effects emitted before the failing directive."
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.DirectiveFailure.Raise do
  use Aikido.Directive

  typed_struct do
    field :message, :string do
      description "Failure raised when this test directive executes."
      default "effect failed"
    end
  end

  @impl true
  def exec(directive, _signal, _runtime), do: raise(directive.message)
end

defmodule AikidoTest.DirectiveFailure.Increment do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    count = input.arguments.state.count + 1

    effects =
      for label <- [:before, :after] do
        %Aikido.Directives.Emit{
          target: input.arguments.target,
          signal: %Aikido.Signal{
            type: "test.effect",
            data: %{label: label, count: count}
          }
        }
      end

    [before, after_failure] = effects

    Aikido.Types.ActionResult.new(
      state: %{count: count},
      directives: [before, %AikidoTest.DirectiveFailure.Raise{}, after_failure]
    )
  end
end

defmodule AikidoTest.DirectiveFailure.Agent do
  use Aikido.Agent

  agent do
    name "directive_failure"

    schema do
      attribute :count, :integer do
        description "Value adopted before any returned directive executes."
        default 0
        allow_nil? false
      end
    end

    route AikidoTest.DirectiveFailure.Signal, AikidoTest.DirectiveFailure.Increment,
      name: :increment
  end
end

defmodule AikidoTest.DirectiveFailureTest do
  use AikidoTest.Case, async: true
  @moduletag capture_log: true

  for delivery <- [:call, :cast] do
    test "#{delivery} retains and checkpoints adopted state after an effect fails", context do
      pid = start_server(context, AikidoTest.DirectiveFailure.Agent)

      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "test.directive_failure",
          &{:ok, &1.agent.state.state.count},
          once: true
        )

      input = AikidoTest.DirectiveFailure.Signal.new!(%{target: self()})

      case unquote(delivery) do
        :call ->
          assert {:error, %RuntimeError{message: "effect failed"}} =
                   Aikido.AgentServer.call(pid, input, fn _ -> raise "selector must not run" end)

        :cast ->
          assert :ok = Aikido.AgentServer.cast(pid, input)
      end

      assert {:ok, 1} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.count})
      assert_receive {:signal, %{type: "test.effect", data: %{label: :before, count: 1}}}
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, 1}}}
      refute_received {:signal, %{type: "test.effect", data: %{label: :after}}}

      replacement = AikidoTest.LifecycleWait.crash_and_await_replacement(pid)
      assert {:ok, 1} = Aikido.AgentServer.state(replacement, &{:ok, &1.agent.state.state.count})

      assert :ok =
               Aikido.Durable.stop(Aikido.durable_supervisor_name(context.aikido), replacement)
    end
  end
end
