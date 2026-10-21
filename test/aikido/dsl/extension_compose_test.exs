defmodule Aikido.Dsl.ExtensionComposeTest.MultiHost do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "multi_host"
    slice :short_term, Aikido.Memory.Slice
    slice :who, Aikido.Identity.Slice
    slice :history, Aikido.Thread.Slice
  end
end

defmodule Aikido.Dsl.ExtensionComposeTest.DefaultPaths do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "host_default_paths"
    slice :memory, Aikido.Memory.Slice
    slice :identity, Aikido.Identity.Slice
  end
end

defmodule Aikido.Dsl.ExtensionComposeTest do
  @moduledoc "Explicit native slices compose on an agent resource."
  use ExUnit.Case, async: true

  describe("multiple mounts compose") do
    test "all three slices mount at the agent-declared paths" do
      instances = Aikido.Agent.Info.slice_instances(Aikido.Dsl.ExtensionComposeTest.MultiHost)
      memory = Enum.find(instances, &(&1.module == Aikido.Memory.Slice))
      identity = Enum.find(instances, &(&1.module == Aikido.Identity.Slice))
      thread = Enum.find(instances, &(&1.module == Aikido.Thread.Slice))
      assert memory.path == :short_term
      assert identity.path == :who
      assert thread.path == :history
    end
  end

  describe("explicit mounts") do
    test "still produce slice instances at the slice's declared path" do
      instances =
        Aikido.Agent.Info.slice_instances(Aikido.Dsl.ExtensionComposeTest.DefaultPaths)

      memory = Enum.find(instances, &(&1.module == Aikido.Memory.Slice))
      identity = Enum.find(instances, &(&1.module == Aikido.Identity.Slice))
      assert memory.path == :memory
      assert identity.path == :identity
    end
  end
end
