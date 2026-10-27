defmodule AikidoTest.AshNativeOptionsTest do
  use ExUnit.Case, async: true

  test "AI options retain defaults, casting and constraints as an Ash type" do
    input =
      ask_input(%{
        query: "Hello",
        request_id: "typed-options",
        options: %{model_timeout_ms: "5000"}
      })

    assert input.valid?, inspect(input.errors)
    assert input.arguments.options.model_timeout_ms == 5_000
    assert input.arguments.options.streaming == false

    invalid =
      ask_input(%{
        query: "Hello",
        request_id: "invalid-typed-options",
        options: %{model_timeout_ms: 0}
      })

    refute invalid.valid?
  end

  test "native option fields preserve unknown keys, ordering, duplicates and nested values" do
    options = [provider_specific: [nested: true], observer: self(), repeat: 1, repeat: nil]

    input =
      ask_input(%{
        query: "Hello",
        request_id: "options",
        tool_options: options,
        llm_opts: options
      })

    assert input.valid?, inspect(input.errors)
    assert input.arguments.tool_options == options
    assert input.arguments.llm_opts == options

    assert {:ok, directive} =
             Aikido.AiReact.Directives.PrepareTools.new(
               request_id: "options",
               tool_options: options
             )

    assert directive.tool_options == options
  end

  test "native tuple fields reject malformed option entries" do
    for options <- [[:not_a_pair], [{123, :value}], [{:key, :value, :extra}]] do
      input =
        ask_input(%{
          query: "Hello",
          request_id: "invalid-options",
          tool_options: options
        })

      refute input.valid?, inspect(options)
    end
  end

  test "recovery flags use native Ash types" do
    for value <- [true, false] do
      assert {:ok, directive} =
               Aikido.Directives.SpawnAgent.new(
                 agent: AikidoTest.TestAgents.Counter,
                 tag: :worker,
                 restart?: value
               )

      assert directive.restart? == value
    end

    assert {:error, _} =
             Aikido.Directives.SpawnAgent.new(
               agent: AikidoTest.TestAgents.Counter,
               tag: :worker,
               restart?: :unsupported
             )
  end

  defp ask_input(arguments) do
    state =
      Aikido.AiReact.Slice
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    Ash.ActionInput.for_action(Aikido.AiReact.Slice, :ask, Map.put(arguments, :state, state))
  end
end
