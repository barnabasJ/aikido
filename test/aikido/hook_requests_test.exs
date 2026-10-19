defmodule Aikido.HookRequestsTest.Agent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

  agent do
    name "hook_requests_test"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end
end

defmodule Aikido.HookRequestsTest.Client do
  @moduledoc false
  @behaviour Aikido.AI.Client

  def generate_text(_model, messages, _opts) do
    text = messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", & &1.text)
    {:ok, %Aikido.Slices.AiReact.Turn{type: :final_answer, text: text}}
  end
end

defmodule Aikido.HookRequestsTest do
  use AikidoTest.Case, async: true
  @moduletag capture_log: true

  @script """
  local answer, err = aikido.request("pick.color", {choices = {"blue", "red"}})
  if err then
    return {decision = "deny", message = err.message}
  end
  return {context = "Lua received " .. answer.value}
  """

  defp hook(callback, script \\ @script, mode \\ :sync) do
    attributes = %{name: "question", event: :before_model, mode: mode, script: script}
    attributes = if callback, do: Map.put(attributes, :request, callback), else: attributes
    {:ok, hook} = Ash.Type.cast_input(Aikido.Hooks.Hook, attributes)

    hook
  end

  test "a callback receives decoded requests and returns into the same Lua script" do
    script = """
    local prefix = "same Lua stack: "
    local answer = aikido.request("pick.color", {choices = {"blue", "red"}})
    return {context = prefix .. answer.value}
    """

    callback = fn request, context ->
      assert request == %{type: "pick.color", payload: %{"choices" => ["blue", "red"]}}
      assert context == %{hook: "question", request_id: "run", event: %{type: :before_model}}
      {:ok, %{value: "blue"}}
    end

    # No AgentServer or transport exists at this PID: the binding only calls our function.
    assert {:ok, %Aikido.Hooks.Decision{context: "same Lua stack: blue"}} =
             Aikido.Hooks.Execute.evaluate(
               hook(callback, script),
               %{type: :before_model},
               self(),
               "run"
             )
  end

  test "the application can wait in its callback while the agent stays responsive", ctx do
    # Compile the Lua request path before the timed mailbox assertions. In the
    # full suite, concurrent fixture compilation can delay BEAM module loading.
    assert {:ok, _} =
             Aikido.Hooks.Execute.evaluate(
               hook(fn _, _ -> {:ok, %{value: "blue"}} end),
               %{type: :before_model},
               self(),
               "warmup"
             )

    pid = start_server(ctx, Aikido.HookRequestsTest.Agent)
    observer = self()

    callback = fn request, context ->
      send(observer, {:question, self(), request, context})

      receive do
        {:answer, response} -> {:ok, response}
      end
    end

    options = [
      model: "offline",
      client: Aikido.HookRequestsTest.Client,
      timeout: 5_000,
      hooks: [hook(callback)]
    ]

    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "hello", options) end)
    assert_receive {:question, waiter, %{type: "pick.color"}, %{request_id: run_id}}, 2_000
    assert is_binary(run_id)
    assert {:ok, :running} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.status})
    send(waiter, {:answer, %{value: "blue"}})
    assert {:ok, answer} = Task.await(task, 5_000)
    assert answer =~ "Lua received blue"

    assert {:ok, false} =
             Aikido.AgentServer.state(
               pid,
               &{:ok, Map.has_key?(&1.agent.state.ai, :hook_requests)}
             )

    refute Ash.Resource.Info.action(Aikido.Slices.AiReact, :respond)
  end

  test "callback errors are returned to Lua for the script to interpret" do
    script = """
    local answer, err = aikido.request("pick.color", {})
    if err then return {context = "handled " .. err.message} end
    return {decision = "deny"}
    """

    assert {:ok, %Aikido.Hooks.Decision{context: "handled :timeout"}} =
             Aikido.Hooks.Execute.evaluate(
               hook(fn _, _ -> {:error, :timeout} end, script),
               %{},
               self(),
               "run"
             )

    assert {:ok, %Aikido.Hooks.Decision{context: "handled :request_callback_not_configured"}} =
             Aikido.Hooks.Execute.evaluate(hook(nil, script), %{}, self(), "run")
  end

  test "Ash's function type validates the callback arity" do
    for callback <- ["not a function", fn _ -> :ok end] do
      assert {:error, _} =
               Ash.Type.cast_input(Aikido.Hooks.Hook, %{
                 name: "bad",
                 event: :before_model,
                 script: @script,
                 request: callback
               })
    end
  end

  test "an invalid callback result is an error that Lua can handle" do
    script = """
    local answer, err = aikido.request("pick.color", {})
    return {decision = "deny", message = err.message}
    """

    assert {:ok, %Aikido.Hooks.Decision{decision: :deny, message: message}} =
             Aikido.Hooks.Execute.evaluate(
               hook(fn _, _ -> :unexpected end, script),
               %{},
               self(),
               "run"
             )

    assert message =~ "Invalid request callback result"
  end

  test "callback exceptions become hook failures" do
    assert {:error, message} =
             Aikido.Hooks.Execute.evaluate(
               hook(fn _, _ -> raise "callback failed" end),
               %{},
               self(),
               "run"
             )

    assert message =~ "callback failed"
  end

  test "asynchronous hooks can use the same application callback" do
    observer = self()

    callback = fn request, _ ->
      send(observer, {:observed_request, request.type})
      {:ok, %{value: "blue"}}
    end

    assert {:ok, nil} =
             Aikido.Hooks.Execute.evaluate(hook(callback, @script, :async), %{}, self(), "run")

    assert_receive {:observed_request, "pick.color"}
  end
end
