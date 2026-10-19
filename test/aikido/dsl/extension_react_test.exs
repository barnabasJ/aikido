defmodule Aikido.Dsl.ExtensionReactTest.SupportAgent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact], default_slices: false

  agent do
    name "support"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [:test_add]
    system_prompt "You are a support agent."
    max_iterations 5
  end
end

defmodule Aikido.Dsl.ExtensionReactTest.RenamedReactAgent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact], default_slices: false

  agent do
    name "renamed_react"
  end

  slices do
    slice :reasoning, Aikido.Slices.AiReact
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [:test_add]
  end
end

defmodule Aikido.Dsl.ExtensionReactTest do
  @moduledoc """
  End-to-end test for `Aikido.Slices.AiReact` contributing a `react do … end`
  block to a host agent. Covers:

    * single-extension contribution (the basic case)
    * `extensions: [{ReAct, as: :slice}]` mounts ReAct slice-only
      (i.e. the same surface as the no-`react`-block fallback)
    * the contributed config flows into the slice's resolved config

  Mimic stubs out `ReqLLM.Generation.generate_text/3` since the slice
  config carries a model spec we need to keep deterministic in tests.
  """
  use ExUnit.Case, async: true

  describe("single contribution: ReAct + react do … end") do
    test "produces a slice instance for ReAct mounted at :ai" do
      instances =
        Aikido.Dsl.Agent.Info.slice_instances(Aikido.Dsl.ExtensionReactTest.SupportAgent)

      react_instance = Enum.find(instances, &(&1.module == Aikido.Slices.AiReact))
      assert react_instance
      assert react_instance.path == :ai
    end

    test "applies the typed-block config to the slice instance" do
      instances =
        Aikido.Dsl.Agent.Info.slice_instances(Aikido.Dsl.ExtensionReactTest.SupportAgent)

      %{config: config} = Enum.find(instances, &(&1.module == Aikido.Slices.AiReact))
      assert config[:model] == "anthropic:claude-haiku-4-5-20251001"
      assert config[:tools] == [:test_add]
      assert config[:system_prompt] == "You are a support agent."
      assert config[:max_iterations] == 5
    end
  end

  describe("agent-declared mount path for ReAct") do
    test "the slice mounts at the agent-declared path even when the typed `react do` block is present" do
      instances =
        Aikido.Dsl.Agent.Info.slice_instances(Aikido.Dsl.ExtensionReactTest.RenamedReactAgent)

      react_instance = Enum.find(instances, &(&1.module == Aikido.Slices.AiReact))
      assert react_instance.path == :reasoning
    end
  end
end
