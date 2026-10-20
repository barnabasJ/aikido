defmodule Aikido.Dsl.InstanceTest.TestInstance do
  @moduledoc false
  use Aikido, otp_app: :aikido
end

defmodule Aikido.Dsl.InstanceTest do
  use ExUnit.Case, async: true

  alias Aikido.Dsl.Instance.Info
  alias Aikido.Dsl.InstanceTest.TestInstance

  test "Spark Info exposes instance configuration and defaults" do
    assert Spark.Dsl.is?(TestInstance, Aikido.Dsl.Instance.Host)
    options = Info.instance_options(TestInstance)
    assert options.otp_app == :aikido
  end

  test "shared config merges overrides and supervision defaults" do
    config = Aikido.config(TestInstance, extra: :value)
    assert config[:extra] == :value
    assert config[:name] == TestInstance
    assert config[:otp_app] == :aikido
  end

  test "instance hosts expose supervision without generated runtime wrappers" do
    assert function_exported?(TestInstance, :child_spec, 1)
    assert function_exported?(TestInstance, :start_link, 1)

    for {name, arity} <- [
          config: 0,
          config: 1,
          __otp_app__: 0,
          __default_slices__: 0,
          start_agent: 1,
          start_agent: 2,
          stop_agent: 1,
          stop_agent: 2,
          whereis: 1,
          whereis: 2,
          list_agents: 0,
          list_agents: 1,
          agent_count: 0,
          agent_count: 1,
          registry_name: 0,
          task_supervisor_name: 0,
          durable_supervisor_name: 0,
          debug: 0,
          debug: 1,
          debug: 2,
          recent: 1,
          recent: 2,
          debug_status: 0
        ] do
      refute function_exported?(TestInstance, name, arity), "Unexpected wrapper #{name}/#{arity}"
    end
  end
end
