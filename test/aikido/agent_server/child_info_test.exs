defmodule AikidoTest.AgentServer.ChildInfoTest do
  use ExUnit.Case, async: true

  alias Aikido.AgentServer.ChildInfo

  describe "new/1" do
    test "creates a ChildInfo with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %ChildInfo{} = child_info} = ChildInfo.new(attrs)
      assert child_info.module == MyChildAgent
      assert child_info.id == "child-456"
      assert child_info.meta == %{}
      assert child_info.tag == nil
    end

    test "creates a ChildInfo with optional tag" do
      attrs = Map.put(valid_attrs(), :tag, :worker)
      assert {:ok, %ChildInfo{tag: :worker}} = ChildInfo.new(attrs)
    end

    test "creates a ChildInfo with custom meta" do
      attrs = Map.put(valid_attrs(), :meta, %{role: :processor})
      assert {:ok, %ChildInfo{meta: %{role: :processor}}} = ChildInfo.new(attrs)
    end

    test "returns error for missing required fields" do
      assert {:error, _reason} = ChildInfo.new(%{})
    end

    test "returns error when missing module" do
      attrs = Map.delete(valid_attrs(), :module)
      assert {:error, _reason} = ChildInfo.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns ChildInfo on success" do
      child_info = ChildInfo.new!(valid_attrs())
      assert %ChildInfo{} = child_info
      assert child_info.id == "child-456"
      assert child_info.module == MyChildAgent
    end

    test "returns ChildInfo with all fields" do
      attrs = valid_attrs() |> Map.put(:tag, :processor) |> Map.put(:meta, %{priority: 1})
      child_info = ChildInfo.new!(attrs)
      assert child_info.tag == :processor
      assert child_info.meta == %{priority: 1}
    end

    test "raises on invalid attrs" do
      assert_raise Ash.Error.Invalid, fn ->
        ChildInfo.new!(%{})
      end
    end
  end

  defp valid_attrs do
    %{
      pid: self(),
      ref: make_ref(),
      module: MyChildAgent,
      id: "child-456"
    }
  end
end
