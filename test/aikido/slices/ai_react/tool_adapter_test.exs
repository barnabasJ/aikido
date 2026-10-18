defmodule Aikido.Slices.AiReact.ToolAdapterTest.AshTools.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :echo}} = input,
        _opts,
        context
      ) do
    {:ok, %{number: input.arguments.number, actor: context.actor}}
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.AshTools do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :count, :integer, public?: true, default: 0
  end

  actions do
    defaults create: :*

    action :echo, :map do
      argument :number, :integer, allow_nil?: false, constraints: [min: 1]
      run Aikido.Slices.AiReact.ToolAdapterTest.AshTools.Implementation
    end
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {:ok, %{}}
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :empty_action, :map do
      description "An action with no parameters"
      run {Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction.Implementation, action: :run}
    end
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.ParamAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {:ok, %{}}
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.ParamAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :param_action, :map do
      argument :query, :string, description: "Search query", allow_nil?: false
      argument :limit, :integer, description: "Max results", default: 10
      description "An action with parameters"
      run {Aikido.Slices.AiReact.ToolAdapterTest.ParamAction.Implementation, action: :run}
    end
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.StrictAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {:ok, %{}}
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.StrictAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :strict_action, :map do
      argument :value, :string, description: "A value", allow_nil?: false
      description "An action that explicitly opts into strict mode"
      run {Aikido.Slices.AiReact.ToolAdapterTest.StrictAction.Implementation, action: :run}
    end
  end

  def strict? do
    true
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.NestedSchemaAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {:ok, %{}}
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.NestedSchemaAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :nested_action, :map do
      argument :name, :string, description: "Name", allow_nil?: false

      argument :config, :map,
        description: "Configuration object",
        allow_nil?: false,
        constraints: [fields: [enabled: [type: :boolean]]]

      argument :items, {:array, :map},
        description: "List of objects",
        allow_nil?: false,
        constraints: [items: [fields: [enabled: [type: :boolean]]]]

      description "An action with nested objects"
      run {Aikido.Slices.AiReact.ToolAdapterTest.NestedSchemaAction.Implementation, action: :run}
    end
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.NotAnAction do
  @moduledoc false
  def some_function do
    :ok
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.DuplicateNameAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {:ok, %{}}
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest.DuplicateNameAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :param_action, :map do
      description "Same name as ParamAction"

      run {Aikido.Slices.AiReact.ToolAdapterTest.DuplicateNameAction.Implementation, action: :run}
    end
  end
end

defmodule Aikido.Slices.AiReact.ToolAdapterTest do
  use ExUnit.Case, async: true

  test "Ash tools use the same input shape, casting, context and errors as AshAI" do
    tool =
      Aikido.Slices.AiReact.ToolAdapter.from_action(
        {Aikido.Slices.AiReact.ToolAdapterTest.AshTools, :echo}
      )

    assert tool.parameter_schema["properties"]["input"]["properties"]["number"]["type"] ==
             "integer"

    definition =
      Aikido.Slices.AiReact.ToolAdapter.ash_tool(
        {Aikido.Slices.AiReact.ToolAdapterTest.AshTools, :echo}
      )

    assert {:ok, _encoded, %{number: 4, actor: %{id: "caller"}}} =
             AshAi.Tools.execute(definition, %{"input" => %{"number" => "4"}}, %{
               actor: %{id: "caller"}
             })

    assert {:error, error} = AshAi.Tools.execute(definition, %{"input" => %{"number" => 0}}, %{})
    assert is_binary(error)
    assert error =~ "number"
  end

  test "Ash create tools reuse AshAI instead of requiring generic actions" do
    assert :ok =
             Aikido.Slices.AiReact.ToolAdapter.validate_actions([
               {Aikido.Slices.AiReact.ToolAdapterTest.AshTools, :create}
             ])

    tool =
      Aikido.Slices.AiReact.ToolAdapter.from_action(
        {Aikido.Slices.AiReact.ToolAdapterTest.AshTools, :create}
      )

    assert tool.parameter_schema["properties"]["input"]["properties"]["count"]["type"] ==
             "integer"

    assert {:ok, _encoded, %Aikido.Slices.AiReact.ToolAdapterTest.AshTools{count: 7}} =
             AshAi.Tools.execute(
               Aikido.Slices.AiReact.ToolAdapter.ash_tool(
                 {Aikido.Slices.AiReact.ToolAdapterTest.AshTools, :create}
               ),
               %{"input" => %{"count" => "7"}},
               %{}
             )
  end

  describe("from_action/2") do
    test "converts action to ReqLLM.Tool struct" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
        )

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "param_action"
      assert tool.description == "An action with parameters"
      assert is_map(tool.parameter_schema)
    end

    test "applies prefix to tool name" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.ParamAction,
          prefix: "myapp_"
        )

      assert tool.name == "myapp_param_action"
    end

    test "auto-detects strict: true via strict?/0 callback" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.StrictAction
        )

      assert tool.strict == true
    end

    test "defaults to strict: false without strict?/0 callback" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
        )

      assert tool.strict == false
    end

    test "respects explicit strict: true override" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.ParamAction,
          strict: true
        )

      assert tool.strict == true
    end

    test "respects explicit strict: false override" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.StrictAction,
          strict: false
        )

      assert tool.strict == false
    end

    test "uses AshAI strict schemas for typed nested objects" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.NestedSchemaAction,
          strict: true
        )

      schema = tool.parameter_schema["properties"]["input"]
      assert schema["additionalProperties"] == false
      assert schema["properties"]["config"]["additionalProperties"] == false
      assert schema["properties"]["items"]["items"]["additionalProperties"] == false
    end

    test "handles empty schema with valid JSON schema output" do
      tool =
        Aikido.Slices.AiReact.ToolAdapter.from_action(
          Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
          strict: true
        )

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "empty_action"

      assert tool.parameter_schema == %{
               "type" => "object",
               "properties" => %{},
               "required" => [],
               "additionalProperties" => false
             }
    end
  end

  describe("from_actions/2") do
    test "converts list of actions to tools" do
      tools =
        Aikido.Slices.AiReact.ToolAdapter.from_actions([
          Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
          Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
        ])

      assert length(tools) == 2
      assert Enum.all?(tools, &match?(%ReqLLM.Tool{}, &1))
    end

    test "applies filter function" do
      tools =
        Aikido.Slices.AiReact.ToolAdapter.from_actions(
          [
            Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
            Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
          ],
          filter: fn mod ->
            to_string(Aikido.ActionRef.definition(mod).name) == "param_action"
          end
        )

      assert length(tools) == 1
      assert hd(tools).name == "param_action"
    end

    test "applies prefix to all tools" do
      tools =
        Aikido.Slices.AiReact.ToolAdapter.from_actions(
          [
            Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
            Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
          ],
          prefix: "v2_"
        )

      assert Enum.all?(tools, fn tool -> String.starts_with?(tool.name, "v2_") end)
    end
  end

  describe("lookup_action/2") do
    test "finds action by tool name" do
      assert {:ok, Aikido.Slices.AiReact.ToolAdapterTest.ParamAction} =
               Aikido.Slices.AiReact.ToolAdapter.lookup_action("param_action", [
                 Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
                 Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
               ])
    end

    test "returns error for unknown tool" do
      assert {:error, :not_found} =
               Aikido.Slices.AiReact.ToolAdapter.lookup_action("unknown", [
                 Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
               ])
    end
  end

  describe("lookup_action/3 with prefix") do
    test "finds action by prefixed tool name" do
      assert {:ok, Aikido.Slices.AiReact.ToolAdapterTest.ParamAction} =
               Aikido.Slices.AiReact.ToolAdapter.lookup_action(
                 "myapp_param_action",
                 [
                   Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
                   Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
                 ],
                 prefix: "myapp_"
               )
    end

    test "returns error when prefix doesn't match" do
      assert {:error, :not_found} =
               Aikido.Slices.AiReact.ToolAdapter.lookup_action(
                 "param_action",
                 [Aikido.Slices.AiReact.ToolAdapterTest.ParamAction],
                 prefix: "myapp_"
               )
    end

    test "returns error for unknown prefixed tool" do
      assert {:error, :not_found} =
               Aikido.Slices.AiReact.ToolAdapter.lookup_action(
                 "myapp_unknown",
                 [Aikido.Slices.AiReact.ToolAdapterTest.ParamAction],
                 prefix: "myapp_"
               )
    end
  end

  describe("validate_actions/1") do
    nil

    test "returns :ok for valid action modules" do
      assert :ok =
               Aikido.Slices.AiReact.ToolAdapter.validate_actions([
                 Aikido.Slices.AiReact.ToolAdapterTest.EmptySchemaAction,
                 Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
               ])
    end

    test "returns error for invalid action module" do
      assert {:error,
              {:invalid_action, Aikido.Slices.AiReact.ToolAdapterTest.NotAnAction, _reason}} =
               Aikido.Slices.AiReact.ToolAdapter.validate_actions([
                 Aikido.Slices.AiReact.ToolAdapterTest.ParamAction,
                 Aikido.Slices.AiReact.ToolAdapterTest.NotAnAction
               ])
    end

    test "returns :not_loaded for a module that cannot be loaded" do
      assert {:error, {:invalid_action, This.Module.Does.Not.Exist, :not_loaded}} =
               Aikido.Slices.AiReact.ToolAdapter.validate_actions([This.Module.Does.Not.Exist])
    end
  end

  describe("to_action_map/1") do
    test "normalizes nil to empty map" do
      assert Aikido.Slices.AiReact.ToolAdapter.to_action_map(nil) == %{}
    end

    test "normalizes list of modules to name => module map" do
      assert Aikido.Slices.AiReact.ToolAdapter.to_action_map([
               Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
             ]) == %{
               to_string(
                 Aikido.ActionRef.definition(Aikido.Slices.AiReact.ToolAdapterTest.ParamAction).name
               ) => Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
             }
    end

    test "normalizes single module to map" do
      assert Aikido.Slices.AiReact.ToolAdapter.to_action_map(
               Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
             ) == %{
               to_string(
                 Aikido.ActionRef.definition(Aikido.Slices.AiReact.ToolAdapterTest.ParamAction).name
               ) => Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
             }
    end

    test "keeps already-normalized maps intact" do
      tools = %{
        to_string(
          Aikido.ActionRef.definition(Aikido.Slices.AiReact.ToolAdapterTest.ParamAction).name
        ) => Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
      }

      assert Aikido.Slices.AiReact.ToolAdapter.to_action_map(tools) == tools
    end

    test "ignores invalid non-module atoms in module lists" do
      assert Aikido.Slices.AiReact.ToolAdapter.to_action_map([
               Aikido.Slices.AiReact.ToolAdapterTest.ParamAction,
               :not_a_module
             ]) == %{
               to_string(
                 Aikido.ActionRef.definition(Aikido.Slices.AiReact.ToolAdapterTest.ParamAction).name
               ) => Aikido.Slices.AiReact.ToolAdapterTest.ParamAction
             }
    end

    test "returns empty map for invalid single atom input" do
      assert Aikido.Slices.AiReact.ToolAdapter.to_action_map(:not_a_module) == %{}
    end
  end

  describe("duplicate detection") do
    (
      nil
      nil
    )

    test "from_actions raises on duplicate tool names" do
      assert_raise ArgumentError, ~r/duplicate tool names/i, fn ->
        Aikido.Slices.AiReact.ToolAdapter.from_actions([
          Aikido.Slices.AiReact.ToolAdapterTest.ParamAction,
          Aikido.Slices.AiReact.ToolAdapterTest.DuplicateNameAction
        ])
      end
    end

    test "from_actions raises on duplicate names after prefix" do
      (
        defmodule Elixir.Aikido.Slices.AiReact.ToolAdapterTest.AAction.Implementation do
          @moduledoc false
          use Ash.Resource.Actions.Implementation
          @impl true
          def run(input, _opts, _context) do
            {:ok, %{}}
          end
        end

        defmodule Elixir.Aikido.Slices.AiReact.ToolAdapterTest.AAction do
          @moduledoc false
          use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

          actions do
            action :action, :map do
              description "First action"
              run {Aikido.Slices.AiReact.ToolAdapterTest.AAction.Implementation, action: :run}
            end
          end
        end
      )

      (
        defmodule Elixir.Aikido.Slices.AiReact.ToolAdapterTest.BAction.Implementation do
          @moduledoc false
          use Ash.Resource.Actions.Implementation
          @impl true
          def run(input, _opts, _context) do
            {:ok, %{}}
          end
        end

        defmodule Elixir.Aikido.Slices.AiReact.ToolAdapterTest.BAction do
          @moduledoc false
          use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

          actions do
            action :action, :map do
              description "Second action with same name"
              run {Aikido.Slices.AiReact.ToolAdapterTest.BAction.Implementation, action: :run}
            end
          end
        end
      )

      assert_raise ArgumentError, ~r/duplicate tool names/i, fn ->
        Aikido.Slices.AiReact.ToolAdapter.from_actions(
          [
            Aikido.Slices.AiReact.ToolAdapterTest.AAction,
            Aikido.Slices.AiReact.ToolAdapterTest.BAction
          ],
          prefix: "test_"
        )
      end
    end
  end
end
