defmodule AikidoTest.AshNativeOptionsTest do
  use ExUnit.Case, async: true

  test "AI options retain defaults, casting and constraints as an Ash type" do
    input =
      Ash.ActionInput.for_action(Aikido.Slices.AiReact, :ask, %{
        query: "Hello",
        request_id: "typed-options",
        options: %{model_timeout_ms: "5000"}
      })

    assert input.valid?, inspect(input.errors)
    assert input.arguments.options.model_timeout_ms == 5_000
    assert input.arguments.options.streaming == false

    invalid =
      Ash.ActionInput.for_action(Aikido.Slices.AiReact, :ask, %{
        query: "Hello",
        request_id: "invalid-typed-options",
        options: %{model_timeout_ms: 0}
      })

    refute invalid.valid?
  end

  test "native option fields preserve unknown keys, ordering, duplicates and nested values" do
    options = [provider_specific: [nested: true], observer: self(), repeat: 1, repeat: nil]

    input =
      Ash.ActionInput.for_action(Aikido.Slices.AiReact, :ask, %{
        query: "Hello",
        request_id: "options",
        tool_options: options,
        llm_opts: options
      })

    assert input.valid?, inspect(input.errors)
    assert input.arguments.tool_options == options
    assert input.arguments.llm_opts == options

    assert {:ok, directive} =
             Aikido.Slices.AiReact.Directives.PrepareTools.new(
               request_id: "options",
               tool_options: options
             )

    assert directive.tool_options == options
  end

  test "native tuple fields reject malformed option entries" do
    for options <- [[:not_a_pair], [{123, :value}], [{:key, :value, :extra}]] do
      input =
        Ash.ActionInput.for_action(Aikido.Slices.AiReact, :ask, %{
          query: "Hello",
          request_id: "invalid-options",
          tool_options: options
        })

      refute input.valid?, inspect(options)
    end
  end

  test "delivery modes and recovery flags use native Ash types" do
    for {action, argument, allowed, arguments} <- [
          {:notify_pid, :delivery_mode, [:async, :sync],
           %{target_pid: self(), signal_type: "test.notify"}},
          {:spawn_child, :restart?, [true, false],
           %{agent_module: AikidoTest.TestAgents.Counter, tag: :worker}}
        ] do
      for value <- allowed do
        input =
          Ash.ActionInput.for_action(
            Aikido.AgentServer.RuntimeActions,
            action,
            Map.put(arguments, argument, value)
          )

        assert input.valid?, inspect(input.errors)
        assert input.arguments[argument] == value
      end

      input =
        Ash.ActionInput.for_action(
          Aikido.AgentServer.RuntimeActions,
          action,
          Map.put(arguments, argument, :unsupported)
        )

      refute input.valid?
    end
  end
end
