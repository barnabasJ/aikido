defmodule Aikido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  # Public DSL extensions share Spark's extension contract.

  @migrated_modules [
    Aikido.Ash.Agent,
    Aikido.Dsl.Instance,
    Aikido.Ash.Slice,
    Ash.Resource.Dsl
  ]

  for module <- @migrated_modules do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
    end
  end

  test "Aikido.Ash.Agent contributes the host-owned sections" do
    section_names = Enum.map(Aikido.Ash.Agent.sections(), & &1.name)
    assert :agent in section_names
    assert :schedules in section_names
  end

  test "Aikido.Dsl.Instance contributes the `instance` section" do
    section_names = Enum.map(Aikido.Dsl.Instance.sections(), & &1.name)
    assert :instance in section_names
  end

  test "Aikido.Ash.Slice contributes the slice surface sections" do
    section_names = Enum.map(Aikido.Ash.Slice.sections(), & &1.name)
    assert :slice in section_names
    assert :schedules in section_names
  end

  test "native Ash provides the actions section" do
    section_names = Enum.map(Ash.Resource.Dsl.sections(), & &1.name)
    assert :actions in section_names
  end
end
