defmodule AgentExamples.NativeLuaToolsTest.EchoImplementation do
  use Ash.Resource.Actions.Implementation

  def run(input, _, context) do
    {:ok, %{text: input.arguments.text, actor: context.actor.id, tenant: context.tenant}}
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Echo do
  use Ash.Resource,
    domain: AgentExamples.NativeLuaToolsTest.Domain,
    data_layer: Ash.DataLayer.Simple

  actions do
    action :echo, :map do
      argument :text, :string, allow_nil?: false
      run AgentExamples.NativeLuaToolsTest.EchoImplementation
    end
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Lua.Actions.Eval do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    options = [
      otp_app: :agent_examples_native_lua,
      action_entrypoints: input.context.shared.entrypoints
    ]

    AshLua.Eval.run(
      input.arguments.script,
      options ++ [actor: context.actor, tenant: context.tenant, context: context.source_context]
    )
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Lua.Actions.Docs do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    options = [
      otp_app: :agent_examples_native_lua,
      action_entrypoints: input.context.shared.entrypoints
    ]

    AshLua.Eval.docs(options, name: "full")
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Lua do
  use Ash.Resource,
    domain: AgentExamples.NativeLuaToolsTest.Domain,
    data_layer: Ash.DataLayer.Simple

  actions do
    action :eval, :map do
      argument :script, :string, allow_nil?: false
      run AgentExamples.NativeLuaToolsTest.Lua.Actions.Eval
    end

    action :docs, :string do
      run AgentExamples.NativeLuaToolsTest.Lua.Actions.Docs
    end
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Assistant do
  use Ash.Resource,
    domain: AgentExamples.NativeLuaToolsTest.Domain,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

  agent do
    name "native_scoped_lua"
    persistence :permanent
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Domain do
  use Ash.Domain,
    otp_app: :agent_examples_native_lua,
    validate_config_inclusion?: false,
    extensions: [AshAi, AshLua.Domain]

  resources do
    resource AgentExamples.NativeLuaToolsTest.Echo
    resource AgentExamples.NativeLuaToolsTest.Lua
    resource AgentExamples.NativeLuaToolsTest.Assistant
  end

  lua do
    namespace "demo" do
      action :echo, AgentExamples.NativeLuaToolsTest.Echo, :echo
    end
  end

  tools do
    tool :scoped_lua, AgentExamples.NativeLuaToolsTest.Lua, :eval
    tool :scoped_lua_docs, AgentExamples.NativeLuaToolsTest.Lua, :docs
  end
end

defmodule AgentExamples.NativeLuaToolsTest.Client do
  def generate_text(_, messages, _) do
    last = List.last(messages)
    text = Enum.map_join(last.content, & &1.text)

    if last.role == :user do
      {:ok,
       %ReqLLM.Response{
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message:
           ReqLLM.Context.assistant("",
             tool_calls: [
               %{id: "lua", name: "scoped_lua", arguments: %{"input" => %{"script" => text}}}
             ]
           ),
         finish_reason: :tool_calls
       }}
    else
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
end

defmodule AgentExamples.NativeLuaToolsTest do
  use ExUnit.Case, async: false
  alias AgentExamples.NativeLuaToolsTest.{Assistant, Echo, Lua, Client}

  setup do
    Application.put_env(:agent_examples_native_lua, :ash_domains, [
      AgentExamples.NativeLuaToolsTest.Domain
    ])

    on_exit(fn -> Application.delete_env(:agent_examples_native_lua, :ash_domains) end)
    :ok
  end

  defp start(entrypoints) do
    {:ok, ref} =
      Assistant
      |> Ash.ActionInput.for_action(:start, %{
        model: "offline",
        client: Client,
        tools: [:scoped_lua, :scoped_lua_docs],
        tool_options: [actions: [{Lua, [:eval, :docs]}]],
        tool_context: %{context: %{shared: %{entrypoints: entrypoints}}}
      })
      |> Ash.run_action()

    on_exit(fn ->
      (Map.get(ref, :resource) || ref.__struct__)
      |> Ash.ActionInput.for_action(:delete, %{agent: ref})
      |> Ash.run_action()
    end)

    ref
  end

  test "Lua execution and docs share per-agent entrypoints and preserve actor and tenant" do
    allowed = start([{Echo, :echo}])
    denied = start([])
    script = "return demo.echo({input = {text = 'hello'}})"
    scope = [actor: %{id: "alice"}, tenant: "workspace"]
    assert {:ok, answer} = AgentExamples.AI.ask(allowed, script, ash: scope)

    assert %{
             "error" => nil,
             "result" => %{"text" => "hello", "actor" => "alice", "tenant" => "workspace"}
           } = Jason.decode!(answer)

    assert {:ok, denied_answer} = AgentExamples.AI.ask(denied, script, ash: scope)
    assert %{"result" => nil, "error" => error} = Jason.decode!(denied_answer)
    assert error

    {_, registry} = AshAi.build_tools_and_registry(actions: [{Lua, [:docs]}])
    docs = registry["scoped_lua_docs"]

    assert {:ok, allowed_docs, _} =
             docs.(%{}, %{context: %{shared: %{entrypoints: [{Echo, :echo}]}}})

    assert allowed_docs =~ "demo.echo"
    assert {:ok, denied_docs, _} = docs.(%{}, %{context: %{shared: %{entrypoints: []}}})
    refute denied_docs =~ "demo.echo"
  end

  test "durable snapshots retain tool selection and rebuild native tools after restart" do
    ref = start([{Echo, :echo}])
    dumped = Aikido.Durable.AgentServer.dump_state(:sys.get_state(ref.pid).user_state)
    snapshot = Aikido.Durable.AgentServer.load_state(1, dumped)
    refute functions?(snapshot)
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(Aikido.Default), ref.pid)

    assert {:ok, restored} =
             Assistant |> Ash.ActionInput.for_action(:start, %{id: ref.id}) |> Ash.run_action()

    assert {:ok, answer} =
             AgentExamples.AI.ask(
               restored,
               "return demo.echo({input = {text = 'restored'}})",
               ash: [actor: %{id: "alice"}, tenant: "workspace"]
             )

    assert answer =~ "restored"
    assert answer =~ "alice"
  end

  defp functions?(value) when is_function(value), do: true

  defp functions?(value) when is_map(value),
    do: Enum.any?(Map.to_list(value), fn {k, v} -> functions?(k) || functions?(v) end)

  defp functions?(value) when is_list(value), do: Enum.any?(value, &functions?/1)
  defp functions?(value) when is_tuple(value), do: value |> Tuple.to_list() |> functions?()
  defp functions?(_), do: false
end
