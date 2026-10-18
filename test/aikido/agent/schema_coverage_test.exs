defmodule AikidoTest.Agent.SchemaCoverageTest.Defaults do
  use Ash.TypedStruct

  typed_struct do
    field :enabled, :boolean, default: false
    field :value, :term
  end
end

defmodule AikidoTest.Agent.SchemaCoverageTest.ResourceDefaults.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :check_enabled}} = input,
        _opts,
        _context
      ) do
    {:ok, input.arguments.enabled}
  end
end

defmodule AikidoTest.Agent.SchemaCoverageTest.ResourceDefaults do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :token, :string, default: &Aikido.Util.generate_id/0, public?: true
    attribute :time, :integer, default: {System, :system_time, [:millisecond]}, public?: true
  end

  actions do
    defaults create: :*

    action :check_enabled, :boolean do
      argument :enabled, :boolean, allow_nil?: false
      run AikidoTest.Agent.SchemaCoverageTest.ResourceDefaults.Implementation
    end
  end
end

defmodule AikidoTest.Agent.SchemaCoverageTest.Nested do
  use Ash.TypedStruct

  typed_struct do
    field :count, :integer, default: 3
  end
end

defmodule AikidoTest.Agent.SchemaCoverageTest.NestedDefaults do
  use Ash.TypedStruct

  typed_struct do
    field :nested, AikidoTest.Agent.SchemaCoverageTest.Nested, default: %{}
  end
end

defmodule AikidoTest.Agent.SchemaCoverageTest do
  use ExUnit.Case, async: true

  test "Ash casts values and enforces bounds" do
    schema = [count: [type: :integer, allow_nil?: false, constraints: [min: 1]]]
    assert {:ok, %{count: 2}} = Aikido.Schema.cast(schema, %{"count" => "2"})
    assert {:error, _} = Aikido.Schema.cast(schema, %{count: 0})
    assert {:error, _} = Aikido.Schema.cast(schema, %{})
    assert {:error, _} = Aikido.Schema.cast(schema, %{count: nil})
  end

  test "false and nil defaults are retained" do
    schema = AikidoTest.Agent.SchemaCoverageTest.Defaults
    assert Aikido.Schema.defaults(schema) == %{enabled: false}
    assert {:ok, %{enabled: false, value: nil}} = Aikido.Schema.cast(schema, %{})
  end

  test "Ash evaluates function and MFA defaults on each construction and preserves explicit nil" do
    schema = AikidoTest.Agent.SchemaCoverageTest.ResourceDefaults
    assert {:ok, first} = Aikido.Schema.cast(schema, %{})
    assert {:ok, second} = Aikido.Schema.cast(schema, %{token: nil})
    assert is_binary(first.token)
    assert second.token == nil
    assert is_integer(first.time)
    assert is_integer(second.time)
  end

  test "native validation errors retain their Splode identity at the action boundary" do
    assert {:error, %Ash.Error.Invalid{} = error} =
             AikidoTest.Agent.SchemaCoverageTest.ResourceDefaults
             |> Ash.ActionInput.for_action(:check_enabled, %{enabled: "invalid"})
             |> Ash.run_action()

    assert Aikido.Error.splode_error?(error)
    assert Aikido.Error.from_term(error) === error
    assert Aikido.Error.to_map(error).type == :validation_error
  end

  test "state contracts remain native typed structs" do
    schema = AikidoTest.Agent.SchemaCoverageTest.Defaults
    assert schema == AikidoTest.Agent.SchemaCoverageTest.Defaults
    assert Ash.Type.NewType.new_type?(schema)
    refute Spark.Dsl.is?(schema, Ash.Resource)
    assert {:ok, typed} = schema.new(%{enabled: "true"})
    assert typed.__struct__ == schema
    assert typed.enabled == true
  end

  test "nested Ash fields apply defaults before casting" do
    schema = AikidoTest.Agent.SchemaCoverageTest.NestedDefaults
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

  def reject_config(_value, _context) do
    {:error, :invalid_config}
  end

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
    assert {:ok, %Aikido.Slices.Memory{}} =
             Ash.Type.cast_input(Aikido.Slices.Memory, %{
               id: "memory",
               created_at: 1,
               updated_at: 1
             })
  end
end
