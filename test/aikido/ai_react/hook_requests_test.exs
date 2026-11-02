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

defmodule Aikido.HookRequestsTest do
  use AikidoTest.Case, async: true
  @moduletag capture_log: true

  defp hook do
    Ash.create!(Aikido.AiReact.Hooks.Hook, %{
      name: "question",
      event: :before_model,
      lua_options: [otp_app: :aikido, labels: [:hook_interactions]],
      script: """
      local answer = assert(interactions.question({input = {choices = {"blue", "red"}}}))
      return {context = "Lua received " .. answer.value}
      """
    })
  end

  test "hooks have no callback attribute or special request binding" do
    refute Ash.Resource.Info.attribute(Aikido.AiReact.Hooks.Hook, :request)

    assert {:error, _} =
             Ash.create(Aikido.AiReact.Hooks.Hook, %{
               name: "invalid",
               event: :before_model,
               script: "return nil",
               request: &String.split/2
             })

    hook =
      Ash.create!(Aikido.AiReact.Hooks.Hook, %{
        name: "surface",
        event: :before_model,
        script: "return {context = type(aikido) == 'nil' and 'absent' or type(aikido.request)}"
      })

    assert {:ok, %{context: "absent"}} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate_lua_hook(hook, %{}, self(), "run")
  end

  test "application action waits in the Lua task while the agent stays responsive", ctx do
    pid = start_server(ctx, Aikido.HookRequestsTest.Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(pid, "hello",
          model: "offline",
          client: Aikido.HookRequestsTest.Client,
          timeout: 5_000,
          hooks: [hook()],
          context: %{observer: observer}
        )
      end)

    assert_receive {:question, waiter, %{choices: ["blue", "red"]}}, 5_000
    assert {:ok, :running} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.status})
    assert {:ok, :queued} = Aikido.AI.queue_message(pid, "queued while the action waits")
    send(waiter, {:answer, %{value: "blue"}})
    assert {:ok, answer} = Task.await(task, 5_000)
    assert answer =~ "Lua received blue"
    assert answer =~ "queued while the action waits"
  end

  test "Lua action configuration survives durable startup and reactivation", ctx do
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = unique_id("lua-actions")

    pid =
      start_server(ctx, Aikido.HookRequestsTest.Agent,
        id: id,
        initial_state: %{
          ai: %{hooks: [hook()], model: "offline", client: Aikido.HookRequestsTest.Client}
        }
      )

    assert {:ok, [original]} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.hooks})
    assert :ok = Aikido.Durable.stop(pool, id)

    assert {:ok, restored} =
             Aikido.Durable.ensure_started(pool, id, agent: Aikido.HookRequestsTest.Agent)

    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert {:ok, [saved]} = Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.ai.hooks})
    assert saved.script == original.script
    assert saved.lua_options == original.lua_options
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(restored, "restored", context: %{observer: observer})
      end)

    assert_receive {:question, waiter, %{choices: ["blue", "red"]}}, 5_000
    send(waiter, {:answer, %{value: "restored"}})
    assert {:ok, answer} = Task.await(task, 5_000)
    assert answer =~ "Lua received restored"
  end
end
