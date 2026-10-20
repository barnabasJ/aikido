defmodule AikidoTest.Agent.NativeContractsTest.ToolResource.Actions.CheckEnabled do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: {:ok, input.arguments.enabled}
end

defmodule AikidoTest.Agent.NativeContractsTest.ToolResource.Actions.CheckSchema do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: {:ok, input.arguments}
end

defmodule AikidoTest.Agent.NativeContractsTest.ToolResource do
  use Ash.Resource, data_layer: :embedded

  actions do
    action :check_enabled, :boolean do
      argument :enabled, :boolean, allow_nil?: false
      run AikidoTest.Agent.NativeContractsTest.ToolResource.Actions.CheckEnabled
    end

    action :check_schema, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 2]
      argument :mode, :atom, constraints: [one_of: [:fast, :slow]]
      argument :count, :integer
      run AikidoTest.Agent.NativeContractsTest.ToolResource.Actions.CheckSchema
    end
  end
end

defmodule AikidoTest.Agent.NativeContractsTest do
  use ExUnit.Case, async: true

  test "native validation errors retain their Splode identity at the action boundary" do
    assert {:error, %Ash.Error.Invalid{} = error} =
             AikidoTest.Agent.NativeContractsTest.ToolResource
             |> Ash.ActionInput.for_action(:check_enabled, %{enabled: "invalid"})
             |> Ash.run_action()

    assert Aikido.Error.splode_error?(error)
    assert Ash.Error.to_error_class(error) == error
  end

  test "typed struct casting returns the declared struct" do
    assert {:ok, %Aikido.Directives.Schedule{delay_ms: 1}} =
             Aikido.Directives.Schedule.new(%{delay_ms: "1", message: :tick})

    assert {:error, _} =
             Aikido.Directives.Schedule.new(%{delay_ms: -1, message: :tick})
  end

  test "tool conversion uses Ash casting without accepting numeric suffixes" do
    tool =
      %AshAi.Tool{
        name: :check_schema,
        resource: AikidoTest.Agent.NativeContractsTest.ToolResource,
        action:
          Ash.Resource.Info.action(
            AikidoTest.Agent.NativeContractsTest.ToolResource,
            :check_schema
          ),
        arguments: [],
        load: []
      }

    assert {:error, error} =
             AshAi.Tools.execute(
               tool,
               %{"input" => %{"name" => "valid", "count" => "12invalid"}},
               %{}
             )

    assert error =~ "count"
  end

  test "JSON tool schemas retain Ash constraints and enum choices" do
    tool =
      %AshAi.Tool{
        name: :check_schema,
        resource: AikidoTest.Agent.NativeContractsTest.ToolResource,
        action:
          Ash.Resource.Info.action(
            AikidoTest.Agent.NativeContractsTest.ToolResource,
            :check_schema
          ),
        arguments: [],
        load: []
      }

    json = AshAi.Tools.parameter_schema(tool, strict: false)["properties"]["input"]
    assert json["required"] == ["name"]
    assert json["properties"]["name"]["type"] == "string"
    assert {:error, _} = AshAi.Tools.execute(tool, %{"input" => %{"name" => "x"}}, %{})
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
