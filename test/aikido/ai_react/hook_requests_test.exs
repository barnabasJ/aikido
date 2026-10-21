defmodule Aikido.HookRequestsTest.Agent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "hook_requests_test"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.HookRequestsTest.Client do
  @moduledoc false
  @behaviour Aikido.AiReact.Client

  def generate_text(_model, messages, _opts) do
    text = messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", & &1.text)

    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant(text, tool_calls: []),
       finish_reason: :stop
     }}
  end
end

defmodule Aikido.HookRequestsTest.PublicAgent do
  use Aikido.Agent, extensions: [Aikido.AI.Extension]

  agent do
    name "hook_requests_public"
  end
end

defmodule Aikido.HookRequestsTest.Callbacks do
  @moduledoc false

  def blue(_request, _context), do: {:ok, %{value: "blue"}}
  def configured(_request, %{event: %{metadata: %{value: value}}}), do: {:ok, %{value: value}}
  def timeout(_request, _context), do: {:error, :timeout}
  def unexpected(_request, _context), do: :unexpected
  def fail(_request, _context), do: raise("callback failed")

  def wait(request, %{event: %{metadata: %{observer: observer}}} = context) do
    send(observer, {:question, self(), request, context})

    receive do
      {:answer, response} -> {:ok, response}
    end
  end

  def observe(request, %{event: %{metadata: %{observer: observer}}}) do
    send(observer, {:observed_request, request.type})
    {:ok, %{value: "blue"}}
  end
end

defmodule Aikido.HookRequestsTest do
  use AikidoTest.Case, async: true
  @moduletag capture_log: true
  alias Aikido.HookRequestsTest.Callbacks

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
    {:ok, hook} = Ash.Type.cast_input(Aikido.AiReact.Hooks.Hook, attributes)

    hook
  end

  test "a callback receives decoded requests and returns into the same Lua script" do
    script = """
    local prefix = "same Lua stack: "
    local answer = aikido.request("pick.color", {choices = {"blue", "red"}})
    return {context = prefix .. answer.value}
    """

    callback = &Callbacks.blue/2

    # No AgentServer or transport exists at this PID: the binding only calls our function.
    assert {:ok, %Aikido.AiReact.Hooks.Decision{context: "same Lua stack: blue"}} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
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
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
               hook(&Callbacks.blue/2),
               %{type: :before_model},
               self(),
               "warmup"
             )

    pid = start_server(ctx, Aikido.HookRequestsTest.Agent)
    observer = self()

    callback = &Callbacks.wait/2

    options = [
      model: "offline",
      client: Aikido.HookRequestsTest.Client,
      timeout: 5_000,
      hooks: [hook(callback)],
      metadata: %{observer: observer}
    ]

    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "hello", options) end)

    assert_receive {:question, waiter,
                    %{type: "pick.color", payload: %{"choices" => ["blue", "red"]}},
                    %{
                      hook: "question",
                      request_id: run_id,
                      event: %{metadata: %{observer: ^observer}}
                    }},
                   2_000

    assert is_binary(run_id)
    assert {:ok, :setup} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.status})
    send(waiter, {:answer, %{value: "blue"}})
    assert {:ok, answer} = Task.await(task, 5_000)
    assert answer =~ "Lua received blue"
    assert {:ok, ai} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
    assert ai.estimated_tokens == Aikido.AiReact.Context.estimate_tokens(ai.context)

    assert {:ok, false} =
             Aikido.AgentServer.state(
               pid,
               &{:ok, Map.has_key?(&1.agent.state.ai, :hook_requests)}
             )

    refute Ash.Resource.Info.action(Aikido.AiReact.Slice, :respond)
  end

  test "callback errors are returned to Lua for the script to interpret" do
    script = """
    local answer, err = aikido.request("pick.color", {})
    if err then return {context = "handled " .. err.message} end
    return {decision = "deny"}
    """

    assert {:ok, %Aikido.AiReact.Hooks.Decision{context: "handled :timeout"}} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
               hook(&Callbacks.timeout/2, script),
               %{},
               self(),
               "run"
             )

    assert {:ok,
            %Aikido.AiReact.Hooks.Decision{
              context: "handled :request_callback_not_configured"
            }} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
               hook(nil, script),
               %{},
               self(),
               "run"
             )
  end

  test "native function constraints reject invalid arity and captured environments" do
    captured = make_ref()

    for callback <- ["not a function", fn _ -> :ok end, fn _, _ -> {:ok, captured} end] do
      assert {:error, _} =
               Ash.Type.cast_input(Aikido.AiReact.Hooks.Hook, %{
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

    assert {:ok, %Aikido.AiReact.Hooks.Decision{decision: :deny, message: message}} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
               hook(&Callbacks.unexpected/2, script),
               %{},
               self(),
               "run"
             )

    assert message =~ "Invalid request callback result"
  end

  test "callback exceptions become hook failures" do
    assert {:error, message} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
               hook(&Callbacks.fail/2),
               %{},
               self(),
               "run"
             )

    assert message =~ "callback failed"
  end

  test "asynchronous hooks can use the same application callback" do
    observer = self()

    callback = &Callbacks.observe/2

    assert {:ok, nil} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate(
               hook(callback, @script, :async),
               %{metadata: %{observer: observer}},
               self(),
               "run"
             )

    assert_receive {:observed_request, "pick.color"}
  end

  test "portable callbacks survive initial Durable startup and checkpoint reactivation", ctx do
    callback = &Callbacks.configured/2
    id = unique_id("portable-hook")

    pid =
      start_server(ctx, Aikido.HookRequestsTest.Agent,
        id: id,
        initial_state: %{
          ai: %{hooks: [hook(callback)], model: "offline", client: Aikido.HookRequestsTest.Client}
        }
      )

    assert {:ok, first} = Aikido.AI.ask_sync(pid, "first", metadata: %{value: "initial"})
    assert first =~ "Lua received initial"

    supervisor = Aikido.durable_supervisor_name(ctx.aikido)

    {key, _} =
      Enum.find(DurableServer.Supervisor.global_members(supervisor), fn {_, {owner, _}} ->
        owner == pid
      end)

    assert {:ok, info} = DurableServer.Supervisor.get_server_info(supervisor, key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    assert {:agent, agent} = saved.agent
    saved_callback = hd(agent.state.ai.hooks).request
    assert Function.info(saved_callback, :type) == {:type, :external}
    assert Function.info(saved_callback, :env) == {:env, []}
    assert saved_callback == callback

    assert :ok = Aikido.Durable.stop(supervisor, id)

    assert {:ok, restored} =
             Aikido.Durable.ensure_started(supervisor, id, agent: Aikido.HookRequestsTest.Agent)

    refute restored == pid
    assert {:ok, second} = Aikido.AI.ask_sync(restored, "second", metadata: %{value: "restored"})
    assert second =~ "Lua received restored"
  end

  test "native public ask forwards serializable metadata to portable hook callbacks", ctx do
    resource = Aikido.HookRequestsTest.PublicAgent

    invalid_start =
      Ash.ActionInput.for_action(resource, :start, %{client: AikidoTest.UnknownHookClient})

    refute invalid_start.valid?

    pid =
      start_server(ctx, resource,
        initial_state: %{
          ai: %{
            model: "offline",
            client: Aikido.HookRequestsTest.Client,
            hooks: [hook(&Callbacks.configured/2)]
          }
        }
      )

    assert {:ok, answer} =
             Aikido.AgentServer.call_until(
               pid,
               fn ->
                 resource
                 |> Ash.ActionInput.for_action(:ask, %{
                   agent: pid,
                   query: "public",
                   metadata: %{value: "native metadata"}
                 })
                 |> Ash.run_action()
               end,
               "ai.react.**",
               fn runtime ->
                 if runtime.agent.state.ai.status == :completed,
                   do: {:ok, runtime.agent.state.ai.result},
                   else: :skip
               end
             )

    assert answer =~ "Lua received native metadata"
  end
end
