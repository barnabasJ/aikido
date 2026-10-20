defmodule AikidoTest.SliceConfigTest.ConfiguredSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "config_contract"

    config_schema do
      attribute :required, :string do
        description "Required payload used to verify native presence validation."
        allow_nil? false
        default "required default"
      end

      attribute :optional, :string do
        description "Optional value used to verify native default handling."
        default "optional default"
      end

      attribute :enabled, :boolean do
        description "Boolean option used to verify native default application."
        default true
      end

      attribute :from_function, :string do
        description "Value supplied by the function default."
        default &AikidoTest.SliceConfigTest.function_default/0
      end

      attribute :from_mfa, :string do
        description "Value supplied by the module-function-arguments default."
        default {String, :upcase, ["mfa default"]}
      end
    end
  end
end

defmodule AikidoTest.SliceConfigTest do
  use ExUnit.Case, async: true

  alias Aikido.Ash.Slice.Config
  alias AikidoTest.SliceConfigTest.ConfiguredSlice

  def function_default do
    send(self(), :function_default_evaluated)
    "function default"
  end

  test "absent fields evaluate native function and MFA defaults" do
    assert {:ok, config} = Config.resolve_config(ConfiguredSlice)
    assert config.required == "required default"
    assert config.optional == "optional default"
    assert config.enabled
    assert config.from_function == "function default"
    assert config.from_mfa == "MFA DEFAULT"
    assert_received :function_default_evaluated
  end

  test "explicit nil and false remain supplied values and defaults are lazy" do
    assert {:ok, config} =
             Config.resolve_config(ConfiguredSlice, %{
               optional: nil,
               enabled: false,
               from_function: nil
             })

    assert config[:optional] == nil
    assert config.enabled == false
    assert config[:from_function] == nil
    refute_received :function_default_evaluated
  end

  test "explicit nil does not bypass required field constraints via a default" do
    assert {:error, _} = Config.resolve_config(ConfiguredSlice, %{required: nil})
    assert {:error, _} = Config.resolve_config(ConfiguredSlice, %{"required" => nil})
  end

  test "atom keys take precedence over string keys, including nil and false" do
    assert {:ok, config} =
             Config.resolve_config(ConfiguredSlice, %{
               "required" => "string value",
               "optional" => "ignored",
               "enabled" => true,
               "from_function" => "supplied",
               :optional => nil,
               :enabled => false
             })

    assert config.required == "string value"
    assert config[:optional] == nil
    assert config.enabled == false
    assert config.from_function == "supplied"
    refute_received :function_default_evaluated
  end
end
