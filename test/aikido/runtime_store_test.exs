defmodule AikidoTest.RuntimeStoreTest do
  use AikidoTest.Case, async: true

  alias Aikido.RuntimeStore

  describe "RuntimeStore" do
    test "supports put/get/fetch/delete within a hive", %{aikido: aikido} do
      assert :error == RuntimeStore.fetch(aikido, :relationships, "child-1")
      assert nil == RuntimeStore.get(aikido, :relationships, "child-1")
      assert :missing == RuntimeStore.get(aikido, :relationships, "child-1", :missing)

      assert :ok ==
               RuntimeStore.put(aikido, :relationships, "child-1", %{
                 parent_id: "parent-1",
                 tag: :worker
               })

      assert {:ok, %{parent_id: "parent-1", tag: :worker}} =
               RuntimeStore.fetch(aikido, :relationships, "child-1")

      assert %{parent_id: "parent-1", tag: :worker} ==
               RuntimeStore.get(aikido, :relationships, "child-1")

      assert :ok == RuntimeStore.delete(aikido, :relationships, "child-1")
      assert :error == RuntimeStore.fetch(aikido, :relationships, "child-1")
    end

    test "keeps hives isolated", %{aikido: aikido} do
      assert :ok == RuntimeStore.put(aikido, :relationships, "child-1", %{parent_id: "parent-1"})
      assert :ok == RuntimeStore.put(aikido, :runtime_flags, :orphan_mode, true)

      assert [orphan_mode: true] == Enum.sort(RuntimeStore.list(aikido, :runtime_flags))
      assert [{"child-1", %{parent_id: "parent-1"}}] == RuntimeStore.list(aikido, :relationships)
    end

    test "retains entries when the RuntimeStore process restarts", %{aikido: aikido} do
      runtime_store = Aikido.runtime_store_name(aikido)
      runtime_store_pid = Process.whereis(runtime_store)
      runtime_store_ref = Process.monitor(runtime_store_pid)

      assert :ok ==
               RuntimeStore.put(aikido, :relationships, "child-1", %{
                 parent_id: "parent-1",
                 tag: :worker
               })

      Process.exit(runtime_store_pid, :kill)
      assert_receive {:DOWN, ^runtime_store_ref, :process, ^runtime_store_pid, :killed}, 1_000

      eventually(fn ->
        case Process.whereis(runtime_store) do
          pid when is_pid(pid) -> pid != runtime_store_pid
          _ -> false
        end
      end)

      assert {:ok, %{parent_id: "parent-1", tag: :worker}} =
               RuntimeStore.fetch(aikido, :relationships, "child-1")
    end
  end
end
