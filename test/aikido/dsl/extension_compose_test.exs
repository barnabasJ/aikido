defmodule Aikido.Dsl.ExtensionComposeTest.MultiHost do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "multi_host"
  end

  slices do
    slice :short_term, Aikido.Slices.Memory
    slice :who, Aikido.Slices.Identity
    slice :history, Aikido.Slices.Thread
  end
end

defmodule Aikido.Dsl.ExtensionComposeTest.HostNoBlocks do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "host_no_blocks"
  end

  slices do
    slice :memory, Aikido.Slices.Memory
    slice :identity, Aikido.Slices.Identity
  end
end

defmodule Aikido.Dsl.ExtensionComposeTest do
  @moduledoc """
  Tests that multiple contributed sections compose cleanly on a single
  host agent (each slice's `<host_section> do … end` block applies
  independently).
  """
  use ExUnit.Case, async: true

  describe("multiple contributions compose") do
    test "all three slices mount at the agent-declared paths" do
      instances = Aikido.Dsl.Agent.Info.slice_instances(Aikido.Dsl.ExtensionComposeTest.MultiHost)
      memory = Enum.find(instances, &(&1.module == Aikido.Slices.Memory))
      identity = Enum.find(instances, &(&1.module == Aikido.Slices.Identity))
      thread = Enum.find(instances, &(&1.module == Aikido.Slices.Thread))
      assert memory.path == :short_term
      assert identity.path == :who
      assert thread.path == :history
    end
  end

  describe("extensions without contribution blocks") do
    test "still produce slice instances at the slice's declared path" do
      instances =
        Aikido.Dsl.Agent.Info.slice_instances(Aikido.Dsl.ExtensionComposeTest.HostNoBlocks)

      memory = Enum.find(instances, &(&1.module == Aikido.Slices.Memory))
      identity = Enum.find(instances, &(&1.module == Aikido.Slices.Identity))
      assert memory.path == :memory
      assert identity.path == :identity
    end
  end
end
