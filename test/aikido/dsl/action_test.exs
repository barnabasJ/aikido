defmodule Aikido.Dsl.ActionTest do
  use ExUnit.Case, async: true

  alias Aikido.Dsl.Action.Info, as: ActionInfo

  describe "sectioned DSL accessor parity" do
    defmodule MinimalAction do
      @moduledoc false
      use Aikido.Action

      action do
        name("minimal")
      end

      def run(_signal, slice, _opts, _ctx) do
        {:ok, slice, []}
      end
    end

    defmodule FullAction do
      @moduledoc false
      use Aikido.Action

      action do
        name("full")
        description("Full action with every accessor populated.")
        category("test")
        tags(["a", "b"])
        vsn("1.2.3")

        schema do
          attribute(:by, :integer, default: 1)
        end

        output_schema do
          attribute(:count, :integer, [])
        end
      end

      def run(%Jido.Signal{data: %{by: by}}, slice, _opts, _ctx) do
        slice = slice || %{count: 0}
        {:ok, %{slice | count: slice.count + by}, []}
      end
    end

    test "name/1 returns the configured name" do
      assert Map.get(ActionInfo.action_options(FullAction), :name) == "full"
      assert Map.get(ActionInfo.action_options(MinimalAction), :name) == "minimal"
    end

    test "description/1, category/1, tags/1, vsn/1 round-trip" do
      assert Map.get(ActionInfo.action_options(FullAction), :description) ==
               "Full action with every accessor populated."

      assert Map.get(ActionInfo.action_options(FullAction), :category) == "test"
      assert Map.get(ActionInfo.action_options(FullAction), :tags) == ["a", "b"]
      assert Map.get(ActionInfo.action_options(FullAction), :vsn) == "1.2.3"
    end

    test "tags/1 defaults to []" do
      assert Map.get(ActionInfo.action_options(MinimalAction), :tags) == []
    end

    test "schema/1 and output_schema/1 round-trip the configured value" do
      assert Aikido.Schema.defaults(ActionInfo.schema(FullAction)) == %{by: 1}
      assert Aikido.Schema.keys(ActionInfo.output_schema(FullAction)) == [:count]
    end

    test "an empty input contract still belongs to its action module" do
      assert ActionInfo.schema(MinimalAction) == MinimalAction
      assert {:ok, %MinimalAction{}} = MinimalAction.new(%{})
      assert ActionInfo.output_schema(MinimalAction) == []
    end

    test "the action itself is its native input struct and Ash type" do
      assert ActionInfo.schema(FullAction) == FullAction
      assert {:ok, %FullAction{by: 7}} = FullAction.new(%{by: "7"})
      assert %FullAction{by: 1} = FullAction.new!(%{})
      assert {:error, _} = FullAction.new(%{by: "invalid"})
      assert Ash.Type.NewType.new_type?(FullAction)
      assert is_boolean(FullAction.handle_change_array?())
      assert is_boolean(FullAction.prepare_change_array?())
    end

    test "Spark.Dsl.is?(mod, Aikido.Action) is true for action modules" do
      assert Spark.Dsl.is?(FullAction, Aikido.Action)
    end

    test "to_json/1 returns the same shape as the legacy macro emit" do
      meta = ActionInfo.to_json(FullAction)
      assert meta.name == "full"
      assert meta.description == "Full action with every accessor populated."
      assert meta.category == "test"
      assert meta.tags == ["a", "b"]
      assert meta.vsn == "1.2.3"
      refute Map.has_key?(meta, :path)
      assert Aikido.Schema.defaults(meta.schema) == %{by: 1}
      assert Aikido.Schema.keys(meta.output_schema) == [:count]
    end
  end

  describe "schema shapes" do
    defmodule AshSchemaAction do
      @moduledoc false
      use Aikido.Action

      action do
        name("ash_schema")

        schema do
          attribute(:value, :integer, allow_nil?: false)
        end

        output_schema do
          attribute(:result, :integer, allow_nil?: false)
        end
      end

      def run(_signal, slice, _opts, _ctx) do
        {:ok, slice, []}
      end
    end

    defmodule DefaultSchemaAction do
      @moduledoc false
      use Aikido.Action

      action do
        name("default_schema")

        schema do
          attribute(:value, :integer, default: 0)
        end
      end

      def run(_signal, slice, _opts, _ctx) do
        {:ok, slice, []}
      end
    end

    test "schema/1 exposes a Ash field contract verbatim" do
      schema = ActionInfo.schema(AshSchemaAction)
      assert Aikido.Action.Schema.schema_type(schema) == :ash
      assert {:ok, %{value: 7}} = Aikido.Schema.cast(schema, %{value: 7})
    end

    test "output_schema/1 exposes a Ash field contract verbatim" do
      schema = ActionInfo.output_schema(AshSchemaAction)
      assert Aikido.Action.Schema.schema_type(schema) == :ash
      assert {:ok, %{result: 5}} = Aikido.Schema.cast(schema, %{result: 5})
    end

    test "schema/1 also accepts a Ash field defaults" do
      assert Aikido.Schema.defaults(ActionInfo.schema(DefaultSchemaAction)) == %{value: 0}
    end
  end

  describe "validate_params/1 and validate_output/1" do
    defmodule ValidatedAction do
      @moduledoc false
      use Aikido.Action

      action do
        name("validated")

        schema do
          attribute(:value, :integer, allow_nil?: false)
        end

        output_schema do
          attribute(:result, :string, [])
        end
      end

      def run(_signal, slice, _opts, _ctx) do
        {:ok, slice, []}
      end
    end

    test "validate_params/1 accepts known params" do
      assert {:ok, %{value: 1}} = ValidatedAction.validate_params(%{value: 1})
    end

    test "validate_output/1 accepts a known output" do
      assert {:ok, %{result: "ok"}} = ValidatedAction.validate_output(%{result: "ok"})
    end
  end

  describe "behaviour" do
    test "modules use Aikido.Action implement the @behaviour" do
      defmodule BehaviourCheckAction do
        @moduledoc false
        use Aikido.Action

        action do
          name("behaviour_check")
        end

        def run(_signal, slice, _opts, _ctx) do
          {:ok, slice, []}
        end
      end

      behaviours =
        BehaviourCheckAction.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Aikido.Action in behaviours
    end
  end
end
