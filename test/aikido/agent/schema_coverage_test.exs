defmodule AikidoTest.Agent.SchemaCoverageTest do
  use ExUnit.Case, async: true

  defmodule Defaults do
    use Aikido.Action

    action do
      name "schema_defaults"

      schema do
        attribute :enabled, :boolean, default: false
        attribute :value, :term
      end
    end

    def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
  end

  defmodule ResourceDefaults do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :token, :string, default: &Aikido.Util.generate_id/0, public?: true
      attribute :time, :integer, default: {System, :system_time, [:millisecond]}, public?: true
    end

    actions do
      defaults create: :*
    end
  end

  defmodule Nested do
    use Ash.TypedStruct

    typed_struct do
      field :count, :integer, default: 3
    end
  end

  defmodule NestedDefaults do
    use Aikido.Action

    action do
      name "nested_defaults"

      schema do
        attribute :nested, Nested, default: %{}
      end
    end

    def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
  end

  test "Ash casts values and enforces bounds" do
    schema = [count: [type: :integer, allow_nil?: false, constraints: [min: 1]]]
    assert {:ok, %{count: 2}} = Aikido.Schema.cast(schema, %{"count" => "2"})
    assert {:error, _} = Aikido.Schema.cast(schema, %{count: 0})
    assert {:error, _} = Aikido.Schema.cast(schema, %{})
    assert {:error, _} = Aikido.Schema.cast(schema, %{count: nil})
  end

  test "false and nil defaults are retained" do
    schema = Aikido.Dsl.Action.Info.schema(Defaults)
    assert Aikido.Schema.defaults(schema) == %{enabled: false}
    assert {:ok, %{enabled: false, value: nil}} = Aikido.Schema.cast(schema, %{})
  end

  test "Ash evaluates function and MFA defaults on each construction and preserves explicit nil" do
    schema = ResourceDefaults
    assert {:ok, first} = Aikido.Schema.cast(schema, %{})
    assert {:ok, second} = Aikido.Schema.cast(schema, %{token: nil})
    assert is_binary(first.token)
    assert second.token == nil
    assert is_integer(first.time)
    assert is_integer(second.time)
  end

  test "native validation errors retain their Splode identity at the action boundary" do
    assert {:error, %Ash.Error.Invalid{} = error} =
             Defaults.validate_params(%{enabled: "invalid"})

    assert Aikido.Error.splode_error?(error)
    assert Aikido.Error.from_term(error) === error
    assert Aikido.Error.to_map(error).type == :validation_error
  end

  test "inline action contracts compile into the action's own native typed struct" do
    schema = Aikido.Dsl.Action.Info.schema(Defaults)
    assert schema == Defaults
    assert Ash.Type.NewType.new_type?(schema)
    refute Spark.Dsl.is?(schema, Ash.Resource)
    assert {:ok, typed} = schema.new(%{enabled: "true"})
    assert typed.__struct__ == schema
    assert typed.enabled == true
  end

  test "nested Ash fields apply defaults before casting" do
    schema = Aikido.Dsl.Action.Info.schema(NestedDefaults)

    assert {:ok, %{nested: %{count: 3}}} = Aikido.Schema.cast(schema, %{})
  end

  test "array constraints apply to each value" do
    schema = [values: [type: {:array, :integer}, constraints: [items: [min: 0]]]]
    assert {:ok, %{values: [1, 2]}} = Aikido.Schema.cast(schema, %{values: ["1", "2"]})
    assert {:error, _} = Aikido.Schema.cast(schema, %{values: [-1]})
  end

  test "typed struct casting returns the declared struct" do
    assert {:ok, %Aikido.Directives.Schedule{delay_ms: 1}} =
             Aikido.Schema.cast(Aikido.Directives.Schedule, %{delay_ms: "1", message: :tick})

    assert {:error, _} =
             Aikido.Schema.cast(Aikido.Directives.Schedule, %{delay_ms: -1, message: :tick})
  end

  test "required Ash strings reject values cast to nil" do
    assert {:error, _} =
             Aikido.Schema.cast([name: [type: :string, allow_nil?: false]], %{name: ""})
  end

  test "tool conversion uses Ash casting without accepting numeric suffixes" do
    schema = [count: [type: :integer, allow_nil?: false]]
    converted = Aikido.Action.Tool.convert_params_using_schema(%{"count" => "12invalid"}, schema)
    assert {:error, _} = Aikido.Action.Schema.validate(schema, converted)
  end

  test "explicit normalization preserves tagged errors" do
    assert {:ok, %{}} = Aikido.Schema.transform(%{}, nil)

    assert {:error, :invalid_config} =
             Aikido.Schema.transform(%{}, {__MODULE__, :reject_config, []})
  end

  def reject_config(_value, _context), do: {:error, :invalid_config}

  test "JSON tool schemas retain Ash constraints and enum choices" do
    schema = [
      name: [type: :string, allow_nil?: false, constraints: [min_length: 2]],
      mode: [type: :atom, constraints: [one_of: [:fast, :slow]]]
    ]

    json = Aikido.Action.Schema.to_json_schema(schema)
    assert json["required"] == ["name"]
    assert json["properties"]["name"]["type"] == "string"
    assert {:error, _} = Aikido.Schema.cast(schema, %{name: "x"})
    assert json["properties"]["mode"]["enum"] == ["fast", "slow"]
  end

  test "runtime structs can be cast through the Ash type API" do
    assert {:ok, %Aikido.Slices.Memory.State{}} =
             Ash.Type.cast_input(Aikido.Slices.Memory.State, %{
               id: "memory",
               created_at: 1,
               updated_at: 1
             })
  end
end
