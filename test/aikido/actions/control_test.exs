defmodule AikidoTest.Actions.ControlTest do
  use ExUnit.Case, async: true
  alias Aikido.Directives
  alias Jido.Signal

  defp sig(type, data \\ %{}) do
    Signal.new!(%{type: type, source: "/test", data: data})
  end

  describe("Cancel") do
    test "sets status to failed with cancelled error" do
      {:ok, %Aikido.Types.ActionResult{state: result, directives: []}} =
        then(sig("cancel", %{reason: :cancelled}), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:cancel, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{status: :failed, error: {:cancelled, :cancelled}}
    end

    test "includes custom cancellation reason" do
      {:ok, %Aikido.Types.ActionResult{state: result, directives: []}} =
        then(sig("cancel", %{reason: :user_requested}), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:cancel, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{status: :failed, error: {:cancelled, :user_requested}}
    end
  end

  describe("Noop") do
    test "preserves the supplied state" do
      {:ok, %Aikido.Types.ActionResult{state: result, directives: []}} =
        then(sig("noop"), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:noop, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
    end
  end

  describe("Forward") do
    test "creates emit directive to target pid" do
      target = self()
      data = %{target_pid: target, signal_type: nil, payload: nil, source: nil}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("forward", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:forward, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.Emit{} = directive
      assert {:pid, opts} = directive.dispatch
      assert Keyword.get(opts, :target) == target
    end

    test "uses custom signal type when provided" do
      target = self()
      data = %{target_pid: target, signal_type: "custom.signal", payload: nil, source: nil}

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("forward", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:forward, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directive.signal.type == "custom.signal"
    end

    test "uses custom payload when provided" do
      target = self()
      data = %{target_pid: target, signal_type: "test", payload: %{key: "value"}, source: nil}

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("forward", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:forward, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directive.signal.data == %{key: "value"}
    end
  end

  describe("Broadcast") do
    test "creates emit directive with pubsub dispatch" do
      data = %{
        topic: "workers",
        signal_type: "work.available",
        payload: %{},
        source: "/broadcast"
      }

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("broadcast", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:broadcast, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.Emit{} = directive
      assert directive.dispatch == {:pubsub, topic: "workers"}
      assert directive.signal.type == "work.available"
    end
  end

  describe("Reply") do
    test "replies to signal with reply_to pid" do
      reply_pid = self()

      input =
        Signal.new!(%{
          type: "query",
          source: "/test",
          data: %{signal_type: "response", payload: %{answer: 42}, reply_to: reply_pid}
        })

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(input, fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:reply, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.Emit{} = directive
      assert directive.signal.type == "response"
      assert directive.signal.data == %{answer: 42}
    end

    test "preserves state when no reply_to is found" do
      input =
        Signal.new!(%{
          type: "query",
          source: "/test",
          data: %{signal_type: "response", payload: %{}}
        })

      {:ok, %Aikido.Types.ActionResult{state: result, directives: []}} =
        then(input, fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:reply, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
    end

    test "leaves state unchanged when the input signal has no reply_to" do
      input =
        Signal.new!(%{
          type: "query",
          source: "/test",
          data: %{signal_type: "response", payload: %{}}
        })

      {:ok, %Aikido.Types.ActionResult{state: result, directives: []}} =
        then(input, fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:reply, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
    end
  end
end
