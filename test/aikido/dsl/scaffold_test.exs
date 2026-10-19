defmodule Aikido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  # Public DSL extensions share Spark's extension contract.

  @migrated_modules [
    Aikido.Dsl.Agent,
    Aikido.Dsl.Instance,
    Aikido.Dsl.Slice,
    Aikido.Dsl.Middleware,
    Ash.Resource.Dsl
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
    assert :schedules in section_names
    assert :capabilities in section_names
    assert :requires in section_names
  end

  test "Aikido.Dsl.Middleware contributes the `middleware` section (task 0035)" do
    section_names = Enum.map(Aikido.Dsl.Middleware.sections(), & &1.name)
    assert :middleware in section_names
  end

  test "native Ash provides the actions section" do
    section_names = Enum.map(Ash.Resource.Dsl.sections(), & &1.name)
    assert :actions in section_names
  end
end
