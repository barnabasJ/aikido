defmodule Aikido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  # Public DSL extensions share Spark's extension contract.

  @migrated_modules [
    Aikido.Agent.Extension,
    Aikido.Instance.Dsl,
    Aikido.Slice.Extension,
    Ash.Resource.Dsl
  ]

  for module <- @migrated_modules do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
    end
  end

  test "Aikido.Agent.Extension contributes the host-owned sections" do
    section_names = Enum.map(Aikido.Agent.Extension.sections(), & &1.name)
    assert :agent in section_names
    assert :schedules in section_names
  end

  test "Aikido.Instance.Dsl contributes the `instance` section" do
    section_names = Enum.map(Aikido.Instance.Dsl.sections(), & &1.name)
    assert :instance in section_names
  end

  test "Aikido.Slice.Extension contributes the slice surface sections" do
    section_names = Enum.map(Aikido.Slice.Extension.sections(), & &1.name)
    assert :slice in section_names
    assert :schedules in section_names
  end

  test "native Ash provides the actions section" do
    section_names = Enum.map(Ash.Resource.Dsl.sections(), & &1.name)
    assert :actions in section_names
  end
end
