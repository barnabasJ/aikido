defmodule Aikido.Dsl.ExtensionPathOverrideTest.HostWithMemoryOverride do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "host_memory_override"
  end

  slices do
    slice :short_term, Aikido.Slices.Memory
  end
end

defmodule Aikido.Dsl.ExtensionPathOverrideTest.HostWithoutMemoryOverride do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "host_memory_default"
  end

  slices do
    slice :memory, Aikido.Slices.Memory
  end
end

defmodule Aikido.Dsl.ExtensionPathOverrideTest do
  @moduledoc "Agent-declared paths bind mounted slices to their state keys."
  use ExUnit.Case, async: true

  describe("agent-declared mount path") do
    test "renames the slice's mount path when the agent picks a non-default" do
      instances =
        Aikido.Dsl.Agent.Info.slice_instances(
          Aikido.Dsl.ExtensionPathOverrideTest.HostWithMemoryOverride
        )

      memory = Enum.find(instances, &(&1.module == Aikido.Slices.Memory))
      assert memory
      assert memory.path == :short_term
    end

    test "uses the path the agent declared in `slices do …`" do
      instances =
        Aikido.Dsl.Agent.Info.slice_instances(
          Aikido.Dsl.ExtensionPathOverrideTest.HostWithoutMemoryOverride
        )

      memory = Enum.find(instances, &(&1.module == Aikido.Slices.Memory))
      assert memory
      assert memory.path == :memory
    end
  end

  describe("Slice.Instance.new/2 path arg") do
    test "uses the supplied path" do
      instance = Aikido.Slice.Instance.new(Aikido.Slices.Memory, :short_term)
      assert instance.path == :short_term
      assert instance.module == Aikido.Slices.Memory
    end

  end
end
