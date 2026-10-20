defmodule Aikido.PureActionsTest do
  use ExUnit.Case, async: true

  alias Aikido.{Directive, Signal}
  alias Aikido.Directives.{Emit, Schedule}
  alias Aikido.Slices.{Identity, Memory, Thread, Todo}

  test "initialized slice updates replay with the input timestamp and stable IDs" do
    signal = Aikido.Signal.new!("test", %{}, time: "2026-10-19T10:11:12Z")
    timestamp = Signal.timestamp(signal)

    for {resource, params} <- [{Identity, %{profile: %{age: 1}}}, {Memory, %{}}, {Thread, %{}}] do
      state = AikidoTest.SliceState.new(resource, params)
      initialized = replay(resource, :ensure, %{state: state} |> Map.merge(params), signal)
      assert initialized.state == state

      result =
        case resource do
          Identity ->
            replay(resource, :evolve, %{state: initialized.state, years: 1}, signal)

          Memory ->
            replay(
              resource,
              :put_in_space,
              %{state: initialized.state, space: :world, key: :hello, value: "world"},
              signal
            )

          Thread ->
            replay(
              resource,
              :append,
              %{
                state: initialized.state,
                entry: [%{payload: %{text: "one"}}, %{payload: %{text: "two"}}]
              },
              signal
            )
        end

      if resource in [Memory, Thread], do: assert(result.state.id == initialized.state.id)
      assert result.state.created_at == initialized.state.created_at
      assert result.state.updated_at == timestamp

      if resource == Thread do
        assert [first, second] = result.state.entries
        assert first.id != second.id
        assert first.at == timestamp
        assert second.at == timestamp
        cleared = replay(Thread, :clear, %{state: result.state}, signal)
        assert cleared.state.updated_at == timestamp
      end
    end
  end

  test "initialized updates without a signal still have deterministic metadata" do
    for {resource, action, params} <- [
          {Identity, :evolve, %{years: 1}},
          {Memory, :put_in_space, %{space: :world, key: :hello, value: "world"}},
          {Thread, :append, %{entry: %{payload: %{text: "one"}}}}
        ] do
      state = AikidoTest.SliceState.new(resource)
      result = replay(resource, action, Map.put(params, :state, state), nil)
      assert result.state.created_at == state.created_at
      assert result.state.updated_at == 0
    end
  end

  test "actions return identical emission descriptors without delivering anything" do
    signal = Aikido.Signal.new!("aikido.todo.add", %{})
    state = AikidoTest.SliceState.new(Todo)

    result =
      replay(Todo, :todo_add, %{state: state, id: "todo", text: "work", timeout_ms: 100}, signal)

    assert [
             %Emit{signal: %{id: nil, time: nil}, target: target},
             %Schedule{message: %{id: nil, time: nil}}
           ] =
             result.directives

    assert target == self()
    refute_received {:signal, _}
    refute_received {:scheduled_signal, _}
  end

  test "Emit and Schedule supply envelope metadata only when executed" do
    signal = Aikido.Signal.new!("test.input", %{}) |> Signal.put(:tenant, "tenant")

    envelope =
      %Aikido.Signal{id: nil, source: "/test", type: "test.output", data: %{value: 1}}

    runtime =
      struct(Aikido.AgentServer.State,
        id: "test",
        agent_module: __MODULE__,
        agent: %{}
      )

    assert :ok = Directive.exec(%Emit{signal: envelope}, signal, runtime)
    assert_receive {:signal, emitted}
    assert is_binary(emitted.id)
    assert is_binary(emitted.time)
    assert Signal.get(emitted, :tenant) == "tenant"

    assert :ok = Directive.exec(%Schedule{delay_ms: 0, message: envelope}, signal, runtime)
    assert_receive {:scheduled_signal, scheduled}
    assert is_binary(scheduled.id)
    assert is_binary(scheduled.time)
    assert scheduled.id != emitted.id
    assert scheduled.data == emitted.data
    assert Signal.get(scheduled, :tenant) == "tenant"

    assert Directive.materialize_signal(emitted) == emitted
  end

  test "the purity check permits native constructors and rejects signal materialization" do
    for function <- [:new, :new!] do
      source = "Aikido.Signal.#{function}(%{type: \"pure\", data: %{value: 1}})"
      assert effect_calls(Code.string_to_quoted!(source)) == []
    end

    for {source, function} <- [
          {~s|Aikido.Signal.new("effect", %{})|, :new},
          {~s|Aikido.Signal.new("effect", %{}, source: "/test")|, :new},
          {~s|Aikido.Signal.new!("effect", %{})|, :new!},
          {~s|Aikido.Signal.new!("effect", %{}, source: "/test")|, :new!},
          {~s|Aikido.Signal.materialize(%{type: "effect"})|, :materialize}
        ] do
      assert [{1, Aikido.Signal, ^function}] = effect_calls(Code.string_to_quoted!(source))
    end

    assert effect_calls(quote(do: Process.send_after(self(), :effect, 1))) != []
  end

  test "reducer implementations do not directly call effect APIs" do
    paths =
      Path.wildcard("lib/aikido/actions/**/*.ex") ++
        Path.wildcard("lib/aikido/slices/**/*.ex") ++
        Path.wildcard("lib/aikido/ash/team/actions/*.ex") ++
        Path.wildcard("examples/agent_app/lib/agent_examples/**/implementation.ex") ++
        [
          "lib/aikido/ash/team/inputs.ex",
          "lib/aikido/ash/team/operation.ex",
          "lib/aikido/ash/team/tasks.ex",
          "lib/aikido/slices/ai_react/handoff.ex",
          "lib/aikido/slices/ai_react/hooks.ex"
        ]

    violations =
      for path <- paths,
          ast = path |> File.read!() |> Code.string_to_quoted!(),
          reducer?(ast) ||
            path in [
              "lib/aikido/ash/team/inputs.ex",
              "lib/aikido/ash/team/operation.ex",
              "lib/aikido/ash/team/tasks.ex",
              "lib/aikido/slices/ai_react/handoff.ex",
              "lib/aikido/slices/ai_react/hooks.ex"
            ],
          violation <- effect_calls(ast),
          do: {path, violation}

    assert violations == []
  end

  defp reducer?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Ash, :Resource, :Actions, :Implementation]} | _]} = node,
        _ ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Aikido, :Types, :ActionResult]}, fun]}, _, _} = node, _
        when fun in [:new, :new!] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp effect_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [module, function]}, metadata, args} = node, calls when is_list(args) ->
          module =
            case module do
              {:__aliases__, _, parts} -> Module.concat(parts)
              atom -> atom
            end

          forbidden? =
            module in [
              Process,
              System,
              Task,
              Task.Supervisor,
              File,
              IO,
              Logger,
              :ets,
              :persistent_term,
              :counters,
              Agent,
              Aikido.AgentServer
            ] ||
              {module, function} in [
                {DateTime, :utc_now},
                {:crypto, :strong_rand_bytes}
              ] ||
              (module == Aikido.Signal &&
                 ((function in [:new, :new!] && length(args) in [2, 3]) ||
                    (function == :materialize && length(args) == 1)))

          {node, if(forbidden?, do: [{metadata[:line], module, function} | calls], else: calls)}

        {function, metadata, args} = node, calls
        when function in [:send, :receive, :spawn, :spawn_link, :make_ref] and is_list(args) ->
          {node, [{metadata[:line], function} | calls]}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp replay(resource, action, params, signal) do
    input =
      Ash.ActionInput.for_action(resource, action, params,
        context: %{aikido: %{signal: signal, slice_path: :test, agent_pid: self()}}
      )

    assert {:ok, %Aikido.Types.ActionResult{} = first} = Ash.run_action(input)
    assert {:ok, second} = Ash.run_action(input)
    assert first == second
    first
  end
end
