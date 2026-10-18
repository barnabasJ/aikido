defmodule AikidoTest.Agent.SchemaTest do
  use ExUnit.Case, async: true
  alias Aikido.Agent.Schema

  test "absent schemas have no fields or defaults" do
    assert Schema.known_keys(nil) == []
    assert Schema.defaults_from_schema(nil) == %{}
    assert Schema.known_keys("invalid") == []
    assert Schema.merge_with_plugins(nil, []) == nil
  end

  defmodule Named do
    use Ash.TypedStruct

    typed_struct do
      field(:name, :string, default: "default")
      field(:count, :integer, allow_nil?: false)
    end
  end

  test "Ash contracts retain defaults and required fields" do
    schema = Named
    assert Schema.known_keys(schema) == [:name, :count]
    assert Schema.defaults_from_schema(schema) == %{name: "default"}
    assert Schema.merge_with_plugins(schema, []) == schema
  end

  test "Ash typed structs expose their field contracts" do
    assert :data in Schema.known_keys(Aikido.Slices.Memory.Space)
    assert Schema.defaults_from_schema(Aikido.Slices.Memory.Space).rev == 0
  end

  test "merging nests each slice at its declared path" do
    base = [mode: [type: :atom]]
    slice = Named

    merged =
      Schema.merge_with_plugins(base, [
        %{path: :counter, schema: slice},
        %{path: :absent, schema: nil}
      ])

    assert Schema.known_keys(merged) == [:mode, :counter]

    assert {:ok, %{mode: :idle, counter: %{name: "default", count: 4}}} =
             Aikido.Schema.cast(merged, %{mode: :idle, counter: %{count: "4"}})
  end

  test "required slices accept the lazy nil placeholder" do
    merged =
      Schema.merge_with_plugins(nil, [
        %{path: :required, schema: [name: [type: :string, allow_nil?: false]]}
      ])

    assert {:ok, %{required: nil}} = Aikido.Schema.cast(merged, %{required: nil})
  end
end
