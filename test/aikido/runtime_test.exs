defmodule AikidoTest.RuntimeTest do
  use AikidoTest.Case, async: true

  alias Aikido.AgentServer
  alias AikidoTest.TestAgents.Minimal

  describe "durable stop with non-existent id" do
    test "returns error when agent not found", %{aikido: aikido} do
      assert {:error, :not_found} =
               Aikido.Durable.stop(
                 Aikido.durable_supervisor_name(aikido),
                 "non-existent-agent-id"
               )
    end
  end

  describe "parent_binding/3" do
    test "returns :error when no parent binding exists", %{aikido: aikido} do
      assert :error =
               Aikido.Durable.parent_binding(
                 Aikido.durable_supervisor_name(aikido),
                 "missing-child"
               )
    end

    test "returns the persisted binding for an adopted child", %{aikido: aikido} do
      {:ok, parent_pid} =
        AikidoTest.Case.start_test_agent(aikido, Minimal, id: "parent-binding-parent")

      {:ok, child_pid} =
        AikidoTest.Case.start_test_agent(aikido, Minimal, id: "parent-binding-child")

      assert {:ok, ^child_pid} = AgentServer.adopt_child(parent_pid, child_pid, :worker)

      assert {:ok, binding} =
               Aikido.Durable.parent_binding(
                 Aikido.durable_supervisor_name(aikido),
                 "parent-binding-child"
               )

      assert binding.parent_id == "parent-binding-parent"
      assert binding.parent_partition == nil
      assert binding.tag == :worker
      assert binding.meta == %{}
    end

    test "respects partitioned bindings", %{aikido: aikido} do
      {:ok, parent_pid} =
        AikidoTest.Case.start_test_agent(aikido, Minimal,
          id: "partitioned-parent",
          partition: :alpha
        )

      {:ok, alpha_child_pid} =
        AikidoTest.Case.start_test_agent(aikido, Minimal, id: "shared-child", partition: :alpha)

      {:ok, _beta_child_pid} =
        AikidoTest.Case.start_test_agent(aikido, Minimal, id: "shared-child", partition: :beta)

      assert {:ok, ^alpha_child_pid} =
               AgentServer.adopt_child(parent_pid, alpha_child_pid, :worker)

      assert {:ok, binding} =
               Aikido.Durable.parent_binding(
                 Aikido.durable_supervisor_name(aikido),
                 "shared-child",
                 partition: :alpha
               )

      assert binding.parent_id == "partitioned-parent"
      assert binding.parent_partition == :alpha
      assert binding.tag == :worker

      assert :error =
               Aikido.Durable.parent_binding(
                 Aikido.durable_supervisor_name(aikido),
                 "shared-child",
                 partition: :beta
               )

      assert :error =
               Aikido.Durable.parent_binding(
                 Aikido.durable_supervisor_name(aikido),
                 "shared-child"
               )
    end
  end

  describe "AgentServer.await_child/3" do
    test "returns timeout when child not found", %{aikido: aikido} do
      {:ok, pid} = AikidoTest.Case.start_test_agent(aikido, Minimal, id: "await-child-delegate")

      result = Aikido.AgentServer.await_child(pid, :nonexistent, timeout: 50)
      assert {:error, :timeout} = result
    end
  end
end
