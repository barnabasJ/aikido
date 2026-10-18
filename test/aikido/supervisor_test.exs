defmodule AikidoTest.SupervisorTest do
  use AikidoTest.Case, async: true

  describe "Aikido supervisor" do
    test "starts a Aikido instance supervisor", %{aikido: aikido} do
      assert is_pid(Process.whereis(aikido))
    end

    test "defaults to Aikido.Default when no name is supplied" do
      assert %{id: Aikido.Default, start: {Aikido, :start_link, [[name: Aikido.Default]]}} =
               Aikido.child_spec([])
    end

    test "can be used as a child spec" do
      name = :"test_aikido_#{System.unique_integer([:positive])}"
      spec = Aikido.child_spec(name: name)
      assert spec.id == name
      assert spec.type == :supervisor
    end

    test "starts TaskSupervisor as child", %{aikido: aikido} do
      task_sup = Aikido.task_supervisor_name(aikido)
      assert Process.whereis(task_sup) != nil

      {:ok, task} = Task.Supervisor.start_child(task_sup, fn -> :ok end)
      assert is_pid(task)
    end

    test "starts Registry as child", %{aikido: aikido} do
      reg = Aikido.registry_name(aikido)
      assert Process.whereis(reg) != nil

      {:ok, _} = Registry.register(reg, "test_key", :test_value)
      assert [{registered_pid, :test_value}] = Registry.lookup(reg, "test_key")
      assert registered_pid == self()

      Registry.unregister(reg, "test_key")
    end

    test "starts the native DurableServer supervisor", %{aikido: aikido} do
      agent_sup = Aikido.durable_supervisor_name(aikido)
      assert Process.whereis(agent_sup) != nil

      assert DurableServer.Supervisor.global_members(agent_sup) == %{}
    end
  end
end
