defmodule Aikido.Dsl.InstanceTest.TestInstance do
  @moduledoc false
  use Aikido, otp_app: :aikido
end

defmodule Aikido.Dsl.InstanceTest do
  use ExUnit.Case, async: true

  test "__otp_app__/0 returns the configured otp_app" do
    assert Aikido.Dsl.InstanceTest.TestInstance.__otp_app__() == :aikido
  end

  test "__aikido_storage__/0 returns the default ETS storage tuple" do
    assert {Aikido.Storage.ETS, _opts} = Aikido.Dsl.InstanceTest.TestInstance.__aikido_storage__()
  end

  test "__default_slices__/0 returns the framework default slices as {path, module} pairs" do
    slices = Aikido.Dsl.InstanceTest.TestInstance.__default_slices__()
    modules = Enum.map(slices, &Aikido.Agent.DefaultSlices.module_of/1)
    assert Aikido.Slices.Memory in modules
    assert Aikido.Slices.Identity in modules
    assert Aikido.Slices.Thread in modules
  end

  test "config/1 reads the runtime config and merges overrides" do
    overrides = [extra: :value]
    config = Aikido.Dsl.InstanceTest.TestInstance.config(overrides)
    assert Keyword.get(config, :extra) == :value
  end

  test "registry_name/0 / durable_supervisor_name/0 / task_supervisor_name/0 are derived" do
    assert Aikido.Dsl.InstanceTest.TestInstance.registry_name() ==
             Aikido.registry_name(Aikido.Dsl.InstanceTest.TestInstance)

    assert Aikido.Dsl.InstanceTest.TestInstance.durable_supervisor_name() ==
             Aikido.durable_supervisor_name(Aikido.Dsl.InstanceTest.TestInstance)

    assert Aikido.Dsl.InstanceTest.TestInstance.task_supervisor_name() ==
             Aikido.task_supervisor_name(Aikido.Dsl.InstanceTest.TestInstance)
  end
end
