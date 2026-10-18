defmodule AikidoTest.Agent.StateTest.Defaults do
  use Ash.TypedStruct

  typed_struct do
    field :count, :integer, default: 10
  end
end

defmodule AikidoTest.Agent.StateTest do
  use ExUnit.Case, async: true

  describe("merge/2") do
    test "merges keyword list into current state" do
      current = %{a: 1, b: 2}
      result = Aikido.Agent.State.merge(current, c: 3, d: 4)
      assert result == %{a: 1, b: 2, c: 3, d: 4}
    end

    test "merges map into current state" do
      current = %{a: 1, b: 2}
      result = Aikido.Agent.State.merge(current, %{c: 3, d: 4})
      assert result == %{a: 1, b: 2, c: 3, d: 4}
    end

    test "deep merges nested maps" do
      current = %{config: %{a: 1, b: 2}}
      result = Aikido.Agent.State.merge(current, %{config: %{b: 3, c: 4}})
      assert result == %{config: %{a: 1, b: 3, c: 4}}
    end

    test "overwrites non-map values" do
      current = %{value: 1}
      result = Aikido.Agent.State.merge(current, %{value: 2})
      assert result == %{value: 2}
    end
  end

  describe("validate/3") do
    test "returns state unchanged for empty schema" do
      state = %{a: 1, b: 2}
      assert {:ok, ^state} = Aikido.Agent.State.validate(state, [])
    end

    test "validates state against Ash field contract" do
      schema = [name: [type: :string, allow_nil?: false], count: [type: :integer]]
      state = %{name: "test", count: 5}
      assert {:ok, validated} = Aikido.Agent.State.validate(state, schema)
      assert validated.name == "test"
      assert validated.count == 5
    end

    test "preserves extra fields in non-strict mode" do
      schema = [name: [type: :string, allow_nil?: false]]
      state = %{name: "test", extra: "field"}
      assert {:ok, validated} = Aikido.Agent.State.validate(state, schema)
      assert validated.extra == "field"
    end

    test "removes extra fields in strict mode" do
      schema = [name: [type: :string, allow_nil?: false]]
      state = %{name: "test", extra: "field"}
      assert {:ok, validated} = Aikido.Agent.State.validate(state, schema, strict: true)
      refute Map.has_key?(validated, :extra)
    end

    test "returns error for invalid state" do
      schema = [count: [type: :integer, allow_nil?: false]]
      state = %{count: "not an integer"}
      assert {:error, _} = Aikido.Agent.State.validate(state, schema)
    end

    test "applies defaults from schema" do
      schema = AikidoTest.Agent.StateTest.Defaults
      state = %{}
      assert {:ok, validated} = Aikido.Agent.State.validate(state, schema)
      assert validated.count == 10
    end

    test "validates against Ash field contract" do
      ash_schema = [
        status: [type: :atom, allow_nil?: false],
        count: [type: :integer, allow_nil?: false]
      ]

      state = %{status: :active, count: 5}
      assert {:ok, validated} = Aikido.Agent.State.validate(state, ash_schema)
      assert validated.status == :active
      assert validated.count == 5
    end

    test "Ash field contract strict mode removes extra fields" do
      ash_schema = [status: [type: :atom, allow_nil?: false]]
      state = %{status: :active, extra: "data"}
      assert {:ok, validated} = Aikido.Agent.State.validate(state, ash_schema, strict: true)
      refute Map.has_key?(validated, :extra)
    end
  end

  describe("native Ash defaults") do
    test "an unconstrained map has no injected defaults" do
      assert {:ok, %{}} = Ash.Type.cast_input(:map, %{})
    end

    test "typed structs apply their own declared defaults" do
      assert {:ok, %AikidoTest.Agent.StateTest.Defaults{count: 10}} =
               AikidoTest.Agent.StateTest.Defaults.new(%{})
    end

    test "an explicit value takes precedence over a native default" do
      assert {:ok, %AikidoTest.Agent.StateTest.Defaults{count: 0}} =
               AikidoTest.Agent.StateTest.Defaults.new(%{count: 0})
    end
  end
end
