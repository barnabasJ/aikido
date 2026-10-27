defmodule AikidoTest.Ownership.ChildTest do
  use ExUnit.Case, async: true

  alias Aikido.Ownership.Child

  describe "new/1" do
    test "creates a Child with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %Child{} = child_info} = Child.new(attrs)
      assert child_info.module == AikidoTest.TestAgents.Basic
      assert child_info.id == "child-456"
      assert child_info.meta == %{}
      assert child_info.tag == nil
    end

    test "creates a Child with optional tag" do
      attrs = Map.put(valid_attrs(), :tag, :worker)
      assert {:ok, %Child{tag: :worker}} = Child.new(attrs)
    end

    test "creates a Child with custom meta" do
      attrs = Map.put(valid_attrs(), :meta, %{role: :processor})
      assert {:ok, %Child{meta: %{role: :processor}}} = Child.new(attrs)
    end

    test "returns error for missing required fields" do
      assert {:error, _reason} = Child.new(%{})
    end

    test "returns error when missing module" do
      attrs = Map.delete(valid_attrs(), :module)
      assert {:error, _reason} = Child.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns Child on success" do
      child_info = Child.new!(valid_attrs())
      assert %Child{} = child_info
      assert child_info.id == "child-456"
      assert child_info.module == AikidoTest.TestAgents.Basic
    end

    test "returns Child with all fields" do
      attrs = valid_attrs() |> Map.put(:tag, :processor) |> Map.put(:meta, %{priority: 1})
      child_info = Child.new!(attrs)
      assert child_info.tag == :processor
      assert child_info.meta == %{priority: 1}
    end

    test "raises on invalid attrs" do
      assert_raise Ash.Error.Invalid, fn ->
        Child.new!(%{})
      end
    end
  end

  defp valid_attrs do
    %{
      pid: self(),
      ref: make_ref(),
      module: AikidoTest.TestAgents.Basic,
      id: "child-456"
    }
  end
end
