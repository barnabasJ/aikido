defmodule AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "fake_memory"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "fake_memory.noop", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "fake_thread"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "fake_thread.noop", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "replacement_memory"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "replacement_memory.noop", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.Agent.DefaultSlicesTest.UserSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "user_slice"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "user_slice.noop", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.Agent.DefaultSlicesTest do
  use ExUnit.Case, async: true

  describe("package_defaults/0") do
    test "returns list of {path, module} tuples for Thread / Identity / Memory slices" do
      assert Aikido.Agent.DefaultSlices.package_defaults() == [
               thread: Aikido.Slices.Thread,
               identity: Aikido.Slices.Identity,
               memory: Aikido.Slices.Memory
             ]
    end
  end

  describe("apply_agent_overrides/2") do
    test "nil overrides returns defaults unchanged" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      assert Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, nil) == defaults
    end

    test "false disables all defaults" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      assert Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, false) == []
    end

    test "empty map returns defaults unchanged" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      assert Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{}) == defaults
    end

    test "exclude a default by path" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      result = Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{thread: false})
      assert result == [memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice]
    end

    test "replace a default with another module" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      result =
        Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{
          memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice
        })

      assert result == [
               memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice,
               thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
             ]
    end

    test "replace a default with module and config tuple" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      result =
        Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{
          memory: {AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice, %{timeout: 5000}}
        })

      assert result == [
               {:memory, AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice,
                %{timeout: 5000}},
               thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
             ]
    end

    test "combine exclude and replace" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      overrides = %{
        thread: false,
        memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice
      }

      result = Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, overrides)
      assert result == [memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice]
    end

    test "invalid override key raises CompileError" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      assert_raise CompileError, ~r/Invalid default_slices override keys/, fn ->
        Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{nonexistent: false})
      end
    end

    test "handles defaults with config tuples" do
      defaults = [
        {:memory, AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice, %{opt: true}},
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      result = Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{thread: false})

      assert result == [
               {:memory, AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice, %{opt: true}}
             ]
    end

    test "replace a default that has config tuple" do
      defaults = [
        {:memory, AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice, %{opt: true}},
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      result =
        Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{
          memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice
        })

      assert result == [
               memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice,
               thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
             ]
    end

    test "exclude all defaults individually" do
      defaults = [
        memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
        thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
      ]

      overrides = %{memory: false, thread: false}
      result = Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, overrides)
      assert result == []
    end

    test "single default list" do
      defaults = [memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice]
      result = Aikido.Agent.DefaultSlices.apply_agent_overrides(defaults, %{memory: false})
      assert result == []
    end
  end

  describe("agent macro integration") do
    test "agent with no default_slices option gets framework defaults" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentNoDefaults do
        use Aikido.Agent

        agent do
          name "ds_agent_no_defaults"
        end
      end

      instances =
        Aikido.Dsl.Agent.Info.slice_instances(AikidoTest.Agent.DefaultSlicesTest.AgentNoDefaults)

      assert length(instances) == 3
      modules = Enum.map(instances, & &1.module)
      assert Aikido.Slices.Thread in modules
      assert Aikido.Slices.Identity in modules
      assert Aikido.Slices.Memory in modules
    end

    test "agent with default_slices: false gets no defaults" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentDisableDefaults do
        use Aikido.Agent, default_slices: false

        agent do
          name "ds_agent_disable_defaults"
        end
      end

      assert Aikido.Dsl.Agent.Info.slice_instances(
               AikidoTest.Agent.DefaultSlicesTest.AgentDisableDefaults
             ) == []
    end

    test "agent with slices still gets them when default_slices is false" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentUserSlicesOnly do
        use Aikido.Agent, default_slices: false

        agent do
          name "ds_agent_user_only"
        end

        slices do
          slice :user_stuff, AikidoTest.Agent.DefaultSlicesTest.UserSlice
        end
      end

      instances =
        Aikido.Dsl.Agent.Info.slice_instances(
          AikidoTest.Agent.DefaultSlicesTest.AgentUserSlicesOnly
        )

      assert length(instances) == 1
      assert hd(instances).module == AikidoTest.Agent.DefaultSlicesTest.UserSlice
    end

    test "agent with aikido: option resolves defaults from instance" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.FakeAikido do
        def __default_slices__ do
          [memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice]
        end
      end

      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentWithAikido do
        use Aikido.Agent, aikido: AikidoTest.Agent.DefaultSlicesTest.FakeAikido

        agent do
          name "ds_agent_with_aikido"
        end
      end

      instances =
        Aikido.Dsl.Agent.Info.slice_instances(AikidoTest.Agent.DefaultSlicesTest.AgentWithAikido)

      assert length(instances) == 1
      assert hd(instances).module == AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice
    end

    test "agent with aikido: and default_slices override map" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.FakeAikido2 do
        def __default_slices__ do
          [
            memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
            thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
          ]
        end
      end

      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentWithAikidoOverride do
        use Aikido.Agent,
          aikido: AikidoTest.Agent.DefaultSlicesTest.FakeAikido2,
          default_slices: %{thread: false}

        agent do
          name "ds_agent_aikido_override"
        end
      end

      instances =
        Aikido.Dsl.Agent.Info.slice_instances(
          AikidoTest.Agent.DefaultSlicesTest.AgentWithAikidoOverride
        )

      assert length(instances) == 1
      assert hd(instances).module == AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice
    end

    test "agent with aikido: and replacement in default_slices" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.FakeAikido3 do
        def __default_slices__ do
          [
            memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice,
            thread: AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice
          ]
        end
      end

      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentWithReplacement do
        use Aikido.Agent,
          aikido: AikidoTest.Agent.DefaultSlicesTest.FakeAikido3,
          default_slices: %{memory: AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice}

        agent do
          name "ds_agent_replacement"
        end
      end

      instances =
        Aikido.Dsl.Agent.Info.slice_instances(
          AikidoTest.Agent.DefaultSlicesTest.AgentWithReplacement
        )

      modules = Enum.map(instances, & &1.module)
      assert AikidoTest.Agent.DefaultSlicesTest.ReplacementMemorySlice in modules
      assert AikidoTest.Agent.DefaultSlicesTest.FakeThreadSlice in modules
      refute AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice in modules
    end

    test "defaults mount before user slices" do
      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.FakeAikido4 do
        def __default_slices__ do
          [memory: AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice]
        end
      end

      defmodule Elixir.AikidoTest.Agent.DefaultSlicesTest.AgentMountOrder do
        use Aikido.Agent, aikido: AikidoTest.Agent.DefaultSlicesTest.FakeAikido4

        agent do
          name "ds_agent_mount_order"
        end

        slices do
          slice :user_stuff, AikidoTest.Agent.DefaultSlicesTest.UserSlice
        end
      end

      instances =
        Aikido.Dsl.Agent.Info.slice_instances(AikidoTest.Agent.DefaultSlicesTest.AgentMountOrder)

      assert length(instances) == 2
      assert Enum.at(instances, 0).module == AikidoTest.Agent.DefaultSlicesTest.FakeMemorySlice
      assert Enum.at(instances, 1).module == AikidoTest.Agent.DefaultSlicesTest.UserSlice
    end
  end
end
