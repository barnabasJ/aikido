defmodule Aikido.DurableActivationContextTest do
  use AikidoTest.Case, async: false

  test "invalid transient activation context fails without exposing its value", %{
    aikido: instance
  } do
    supervisor = Aikido.durable_supervisor_name(instance)

    for operation <- [:start, :ensure_started] do
      id = Ash.UUIDv7.generate()

      assert_raise ArgumentError, ":init_context must be a map", fn ->
        apply(Aikido.Durable, operation, [
          supervisor,
          id,
          [agent: AikidoTest.TestAgents.Counter],
          [init_context: "private-context-that-must-not-appear-in-errors"]
        ])
      end

      assert :error = Aikido.Durable.lookup(supervisor, id)
    end
  end
end
