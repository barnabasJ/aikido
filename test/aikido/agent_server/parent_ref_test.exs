defmodule AikidoTest.AgentServer.ParentRefTest do
  use ExUnit.Case, async: true

  alias Aikido.AgentServer.ParentRef

  @valid_attrs %{
    pid: self(),
    id: "parent-123",
    tag: :worker
  }

  describe "new/1" do
    test "creates a ParentRef with valid attrs" do
      assert {:ok, %ParentRef{} = parent_ref} = ParentRef.new(@valid_attrs)
      assert parent_ref.id == "parent-123"
      assert parent_ref.tag == :worker
      assert parent_ref.meta == %{}
    end

    test "creates a ParentRef with custom meta" do
      attrs = Map.put(@valid_attrs, :meta, %{priority: :high})
      assert {:ok, %ParentRef{meta: %{priority: :high}}} = ParentRef.new(attrs)
    end

    test "returns error for missing required fields" do
      assert {:error, _reason} = ParentRef.new(%{})
    end
  end

  describe "new!/1" do
    test "returns ParentRef on success" do
      parent_ref = ParentRef.new!(@valid_attrs)
      assert %ParentRef{} = parent_ref
      assert parent_ref.id == "parent-123"
    end

    test "raises on invalid attrs" do
      assert_raise Ash.Error.Invalid, fn ->
        ParentRef.new!(%{})
      end
    end
  end
end
