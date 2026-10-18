defmodule AikidoTest.Agent.StateTest do
  use ExUnit.Case, async: true

  alias Aikido.Agent.State

  defmodule Defaults do
    use Aikido.Action

    action do
      name "state_defaults"

      schema do
        attribute :count, :integer, default: 10
      end
    end

    def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
  end

  describe "merge/2" do
    test "merges keyword list into current state" do
      current = %{a: 1, b: 2}
      result = State.merge(current, c: 3, d: 4)

      assert result == %{a: 1, b: 2, c: 3, d: 4}
    end

    test "merges map into current state" do
      current = %{a: 1, b: 2}
      result = State.merge(current, %{c: 3, d: 4})

      assert result == %{a: 1, b: 2, c: 3, d: 4}
    end

    test "deep merges nested maps" do
      current = %{config: %{a: 1, b: 2}}
      result = State.merge(current, %{config: %{b: 3, c: 4}})

      assert result == %{config: %{a: 1, b: 3, c: 4}}
    end

    test "overwrites non-map values" do
      current = %{value: 1}
      result = State.merge(current, %{value: 2})

      assert result == %{value: 2}
    end
  end

  describe "validate/3" do
    test "returns state unchanged for empty schema" do
      state = %{a: 1, b: 2}

      assert {:ok, ^state} = State.validate(state, [])
    end

    test "validates state against Ash field contract" do
      schema = [name: [type: :string, allow_nil?: false], count: [type: :integer, default: 0]]

      state = %{name: "test", count: 5}

      assert {:ok, validated} = State.validate(state, schema)
      assert validated.name == "test"
      assert validated.count == 5
    end

    test "preserves extra fields in non-strict mode" do
      schema = [name: [type: :string, allow_nil?: false]]
      state = %{name: "test", extra: "field"}

      assert {:ok, validated} = State.validate(state, schema)
      assert validated.extra == "field"
    end

    test "removes extra fields in strict mode" do
      schema = [name: [type: :string, allow_nil?: false]]
      state = %{name: "test", extra: "field"}

      assert {:ok, validated} = State.validate(state, schema, strict: true)
      refute Map.has_key?(validated, :extra)
    end

    test "returns error for invalid state" do
      schema = [count: [type: :integer, allow_nil?: false]]
      state = %{count: "not an integer"}

      assert {:error, _} = State.validate(state, schema)
    end

    test "applies defaults from schema" do
      schema = Aikido.Dsl.Action.Info.schema(Defaults)
      state = %{}

      assert {:ok, validated} = State.validate(state, schema)
      assert validated.count == 10
    end

    test "validates against Ash field contract" do
      ash_schema = [
        status: [type: :atom, allow_nil?: false],
        count: [type: :integer, allow_nil?: false]
      ]

      state = %{status: :active, count: 5}

      assert {:ok, validated} = State.validate(state, ash_schema)
      assert validated.status == :active
      assert validated.count == 5
    end

    test "Ash field contract strict mode removes extra fields" do
      ash_schema = [status: [type: :atom, allow_nil?: false]]
      state = %{status: :active, extra: "data"}

      assert {:ok, validated} = State.validate(state, ash_schema, strict: true)
      refute Map.has_key?(validated, :extra)
    end
  end

  describe "defaults_from_schema/1" do
    test "returns empty map for empty schema" do
      assert State.defaults_from_schema([]) == %{}
    end

    test "extracts defaults from Ash field contract" do
      schema = [
        name: [type: :string, default: "default_name"],
        count: [type: :integer, default: 0],
        status: [type: :atom]
      ]

      defaults = State.defaults_from_schema(schema)

      assert defaults == %{name: "default_name", count: 0}
    end

    test "only includes keys with defaults" do
      schema = [
        with_default: [type: :string, default: "value"],
        without_default: [type: :integer, allow_nil?: false]
      ]

      defaults = State.defaults_from_schema(schema)

      assert Map.has_key?(defaults, :with_default)
      refute Map.has_key?(defaults, :without_default)
    end
  end
end
