defmodule Aikido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  # All `Aikido.Dsl.*` extensions are now filled in. Task 0034 wired
  # `Aikido.Dsl.Agent` and `Aikido.Dsl.Instance`. Task 0035 wired
  # `Aikido.Dsl.Slice` and `Aikido.Dsl.Middleware`. Task 0036 wired
  # `Aikido.Dsl.Action` and `Aikido.Dsl.Sensor`.

  @migrated_modules [
    Aikido.Dsl.Agent,
    Aikido.Dsl.Instance,
    Aikido.Dsl.Slice,
    Aikido.Dsl.Middleware,
    Aikido.Dsl.Action,
    Aikido.Dsl.Sensor
  ]

  for module <- @migrated_modules do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
    end
  end

  test "Aikido.Dsl.Agent contributes the host-owned sections (task 0034)" do
    section_names = Enum.map(Aikido.Dsl.Agent.sections(), & &1.name)
    assert :agent in section_names
    assert :signal_routes in section_names
    assert :schedules in section_names
  end

  test "Aikido.Dsl.Instance contributes the `instance` section (task 0034)" do
    section_names = Enum.map(Aikido.Dsl.Instance.sections(), & &1.name)
    assert :instance in section_names
  end

  test "Aikido.Dsl.Slice contributes the slice surface sections (task 0035)" do
    section_names = Enum.map(Aikido.Dsl.Slice.sections(), & &1.name)
    assert :slice in section_names
    assert :signal_routes in section_names
    assert :subscriptions in section_names
    assert :schedules in section_names
    assert :capabilities in section_names
    assert :requires in section_names
  end

  test "Aikido.Dsl.Middleware contributes the `middleware` section (task 0035)" do
    section_names = Enum.map(Aikido.Dsl.Middleware.sections(), & &1.name)
    assert :middleware in section_names
  end

  test "Aikido.Dsl.Action contributes the `action` section (task 0036)" do
    section_names = Enum.map(Aikido.Dsl.Action.sections(), & &1.name)
    assert :action in section_names
  end

  test "Aikido.Dsl.Sensor contributes the `sensor` section (task 0036)" do
    section_names = Enum.map(Aikido.Dsl.Sensor.sections(), & &1.name)
    assert :sensor in section_names
  end
end
