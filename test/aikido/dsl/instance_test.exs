defmodule Aikido.Dsl.InstanceTest do
  use ExUnit.Case, async: true

  defmodule TestInstance do
    @moduledoc false
    use Aikido, otp_app: :aikido
  end

  test "__otp_app__/0 returns the configured otp_app" do
    assert TestInstance.__otp_app__() == :aikido
  end

  test "__aikido_storage__/0 returns the default ETS storage tuple" do
    assert {Aikido.Storage.ETS, _opts} = TestInstance.__aikido_storage__()
  end

  test "__default_slices__/0 returns the framework default slices as {path, module} pairs" do
    slices = TestInstance.__default_slices__()
    modules = Enum.map(slices, &Aikido.Agent.DefaultSlices.module_of/1)
    assert Aikido.Slices.Memory in modules
    assert Aikido.Slices.Identity in modules
    assert Aikido.Slices.Thread in modules
  end

  test "config/1 reads the runtime config and merges overrides" do
    overrides = [extra: :value]
    config = TestInstance.config(overrides)
    assert Keyword.get(config, :extra) == :value
  end

  test "registry_name/0 / agent_supervisor_name/0 / task_supervisor_name/0 / runtime_store_name/0 are derived" do
    assert TestInstance.registry_name() == Aikido.registry_name(TestInstance)
    assert TestInstance.agent_supervisor_name() == Aikido.agent_supervisor_name(TestInstance)
    assert TestInstance.task_supervisor_name() == Aikido.task_supervisor_name(TestInstance)
    assert TestInstance.runtime_store_name() == Aikido.runtime_store_name(TestInstance)
  end
end
