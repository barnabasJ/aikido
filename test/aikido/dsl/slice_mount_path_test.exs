defmodule Aikido.Dsl.SliceMountPathTest.RenamedMemoryHost do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "renamed_memory_host"
    slice :short_term, Aikido.Memory.Slice
  end
end

defmodule Aikido.Dsl.SliceMountPathTest.MemoryHost do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "memory_host"
    slice :memory, Aikido.Memory.Slice
  end
end

defmodule Aikido.Dsl.SliceMountPathTest do
  @moduledoc "Agent-declared paths bind mounted slices to their state keys."
  use ExUnit.Case, async: true

  describe("agent-declared mount path") do
    test "uses an agent-declared path independently of the slice name" do
      instances =
        Aikido.Agent.Info.slice_instances(Aikido.Dsl.SliceMountPathTest.RenamedMemoryHost)

      memory = Enum.find(instances, &(&1.module == Aikido.Memory.Slice))
      assert memory
      assert memory.path == :short_term
    end

    test "uses the explicit agent slice mount path" do
      instances =
        Aikido.Agent.Info.slice_instances(Aikido.Dsl.SliceMountPathTest.MemoryHost)

      memory = Enum.find(instances, &(&1.module == Aikido.Memory.Slice))
      assert memory
      assert memory.path == :memory
    end
  end

  describe("Slice.Instance.new/2 path arg") do
    test "uses the supplied path" do
      instance = Aikido.Slice.Instance.new(Aikido.Memory.Slice, :short_term)
      assert instance.path == :short_term
      assert instance.module == Aikido.Memory.Slice
    end
  end
end
