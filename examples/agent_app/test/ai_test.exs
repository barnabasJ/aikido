defmodule AgentExamples.AITest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias AgentExamples.{Agents, AI}

  defmodule RuntimeClient do
    @behaviour Aikido.AI.Client
    def generate_text(%{probe: probe} = model, messages, options) do
      send(probe, {:runtime_model_call, model, messages, options})

      {:ok,
       struct!(ReqLLM.Response,
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("runtime configured", tool_calls: []),
         finish_reason: :stop
       )}
    end
  end

  defp track(%{resource: resource} = reference),
    do:
      track(
        resource
        |> Ash.ActionInput.for_action(:inspect, %{agent: reference})
        |> Ash.run_action!()
      )

  defp track(record) do
    on_exit(fn ->
      (Map.get(record, :resource) || record.__struct__)
      |> Ash.ActionInput.for_action(:stop, %{agent: record})
      |> Ash.run_action()
    end)

    record
  end

  test "model and tools are sufficient for real agents and teams" do
    for create <- [&Agents.assistant_start!/1, &Agents.research_team_start!/1] do
      record = track(create.(%{model: "zai:glm-5.3", tools: []}))
      assert record.client == ReqLLM.Generation
      assert record.model == "zai:glm-5.3"

      assert {:ok, ReqLLM.Generation} =
               Aikido.AgentServer.state(
                 case Aikido.Durable.lookup(
                        Aikido.durable_supervisor_name(Aikido.Default),
                        record.id
                      ) do
                   {:ok, pid} -> pid
                   :error -> nil
                 end,
                 &{:ok, &1.agent.state.ai.client}
               )
    end
  end

  test "all AI defaults can be overridden through the public create interface" do
    for create <- [&Agents.assistant_start!/1, &Agents.research_team_start!/1] do
      model = %{id: "external-model", probe: self()}

      record =
        track(
          create.(%{
            model: model,
            client: RuntimeClient,
            system_prompt: "Configured by the caller",
            max_iterations: 3,
            tools: []
          })
        )

      assert record.model == model
      assert record.client == RuntimeClient
      assert record.system_prompt == "Configured by the caller"
      assert record.max_iterations == 3

      pid =
        case Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), record.id) do
          {:ok, pid} -> pid
          :error -> nil
        end

      assert {:ok, %{system_prompt: "Configured by the caller", max_iterations: 3}} =
               Aikido.AgentServer.state(
                 pid,
                 &{:ok, Map.take(&1.agent.state.ai, [:system_prompt, :max_iterations])}
               )

      assert {:ok, "runtime configured"} = AI.ask(record, "Hello")

      assert_receive {:runtime_model_call, ^model,
                      [%{role: :system, content: [%{text: "Configured by the caller"}]} | _], _}
    end

    assert {:error, _} = snapshot_result(Agents.assistant_start(%{max_iterations: 0}))
  end

  test "AI teams accept caller-defined topology and inherit runtime model and tools" do
    tools = AI.Tools.for_assistant()

    team =
      track(
        Agents.research_team_start!(
          AI.offline(%{
            tools: tools,
            topology: %{"custom" => %{resource: AgentExamples.Researcher}}
          })
        )
      )

    assert Map.keys(team.team.members) == ["custom"]
    worker = member(team, "custom")
    assert worker.model == "offline"
    assert worker.client == AI.ScriptedClient
    assert worker.tools == tools
    assert {:ok, answer} = AI.ask(team, "Signals carry results")
    assert answer =~ "Words: 3"
  end

  test "an agent and a team expose the same runtime tools and ask interface" do
    assistant =
      track(
        snapshot_result(
          Agents.assistant_start!(
            AI.offline(%{
              tool_context: %{context: %{stamp_label: "solo"}},
              tools: AI.Tools.for_assistant()
            })
          )
        )
      )

    team =
      track(
        snapshot_result(
          Agents.research_team_start!(
            AI.offline(%{
              tool_context: %{context: %{stamp_label: "team"}},
              tools: AI.Tools.for_assistant()
            })
          )
        )
      )

    assert {:ok, answer} = AI.ask(assistant, "Signals carry results")
    assert answer =~ "Words: 3"
    assert answer =~ "solo: Signals carry results"
    assert {:ok, answer} = AI.ask(team, "Signals carry results")
    assert answer =~ "Words: 3"
    assert answer =~ "team: Signals carry results"
  end

  test "orchestrator and fixed worker both create and delegate to dynamic workers" do
    tools = AI.Tools.for_team()
    team = track(snapshot_result(Agents.research_team_start!(AI.offline(%{tools: tools}))))
    assert Map.keys(team.team.members) |> Enum.sort() == [:analyst, :reviewer]

    assert {:ok, answer} = AI.ask(team, "orchestrate: Signals carry results")
    assert answer =~ "Started specialist"
    assert answer =~ "Started analyst-helper"
    assert answer =~ "analyst-helper:"
    assert answer =~ "reviewer:"
    assert answer =~ "specialist:"
    refute answer =~ "Tool error:"

    current = AgentExamples.Agents.research_team_inspect!(team.id)
    assert current.team.topology.nodes["specialist"].owner == nil
    assert current.team.topology.nodes["analyst-helper"].owner == :analyst
    assert map_size(current.team.members) == 4

    assert Enum.all?(current.team.tasks, fn {_, task} ->
             task.status == :completed && task.result =~ "Words: 3"
           end)

    for {name, pid} <- current.team.members do
      resource = current.team.topology.nodes[name].resource
      {:ok, id} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.id})
      member = resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action!()
      assert member.tools == tools
      assert member.client == AI.ScriptedClient
      assert member.model == "offline"
    end

    # Removing the fixed owner also removes its dynamically spawned subtree.
    {:ok, changed} =
      snapshot_result(Agents.research_team_remove_member(current, %{member: :analyst}))

    state = changed.team
    assert state.operation.status == :completed
    refute Map.has_key?(state.members, :analyst)
    refute Map.has_key?(state.members, "analyst-helper")
    assert Map.has_key?(state.members, "specialist")
  end

  test "actual Ash AI callbacks and AshLua tools run through the model loop" do
    tools = AI.Tools.for_lua()

    assert Enum.sort(Enum.map(tools, &to_string/1)) ==
             ["lua_docs", "run_lua"]

    assistant = track(snapshot_result(Agents.assistant_start!(AI.offline(%{tools: tools}))))
    assert {:ok, answer} = AI.ask(assistant, "Signals carry results")
    assert answer =~ "Words: 3"
    assert answer =~ "Lua:"
    refute answer =~ "stub"
    refute answer =~ "Tool error:"
  end

  test "native Ash AI tools receive per-instance application context" do
    assistant =
      track(
        snapshot_result(
          Agents.assistant_start!(
            AI.offline(%{
              tools: [:stamp],
              tool_context: %{context: %{stamp_label: "context"}}
            })
          )
        )
      )

    assert {:ok, "context: hello"} = AI.ask(assistant, "hello")
  end

  test "an AI orchestrator and its worker spawn agents using only AshLua tools" do
    tools = AI.Tools.for_lua()
    team = track(snapshot_result(Agents.research_team_start!(AI.offline(%{tools: tools}))))
    assert {:ok, answer} = AI.ask(team, "orchestrate: Signals carry results", timeout: 30_000)
    refute answer =~ "Tool error:"
    assert answer =~ "Words: 3"
    current = AgentExamples.Agents.research_team_inspect!(team.id)
    assert current.team.topology.nodes["specialist"].owner == nil
    assert current.team.topology.nodes["analyst-helper"].owner == :analyst
    assert map_size(current.team.members) == 4
    assert Enum.all?(current.team.tasks, fn {_, task} -> task.status == :completed end)
    assert Enum.all?(tools, &(&1 not in [:spawn_worker, :delegate]))
  end

  test "Lua can spawn teams, scope nested team management, and stop and remove owned workers" do
    team =
      track(
        snapshot_result(Agents.research_team_start!(AI.offline(%{tools: AI.Tools.for_lua()})))
      )

    assert {:ok, %{error: nil}} =
             lua(
               team,
               "return assert(agents.spawn({input = {name = 'squad-a', template = 'squad'}}))"
             )

    current = AgentExamples.Agents.research_team_inspect!(team.id)
    squad = member(current, "squad-a")
    assert squad.__struct__ == AgentExamples.ResearchSquad
    assert squad.tools == team.tools

    assert squad.system_prompt ==
             Ash.Resource.Info.attribute(AgentExamples.ResearchSquad, :system_prompt).default

    refute squad.system_prompt == team.system_prompt

    assert {:ok, %{error: nil}} =
             lua(squad, "return assert(agents.spawn({input = {name = 'squad-worker'}}))")

    squad = AgentExamples.Agents.research_squad_inspect!(squad.id)
    assert Map.has_key?(squad.team.members, "squad-worker")

    refute Map.has_key?(
             AgentExamples.Agents.research_team_inspect!(team.id).team.members,
             "squad-worker"
           )

    analyst = member(current, :analyst)

    assert analyst.system_prompt ==
             Ash.Resource.Info.attribute(AgentExamples.Researcher, :system_prompt).default

    refute analyst.system_prompt == team.system_prompt

    assert {:ok, %{error: nil}} =
             lua(analyst, "return assert(agents.spawn({input = {name = 'lua-helper'}}))")

    current = AgentExamples.Agents.research_team_inspect!(team.id)
    assert current.team.topology.nodes["lua-helper"].owner == :analyst
    helper = current.team.members["lua-helper"]
    ref = Process.monitor(helper)

    assert {:ok, %{error: nil}} =
             lua(analyst, "return assert(agents.stop({input = {member = 'lua-helper'}}))")

    assert_receive {:DOWN, ^ref, :process, ^helper, _}, 5_000
    current = AgentExamples.Agents.research_team_inspect!(team.id)
    assert Map.has_key?(current.team.topology.nodes, "lua-helper")
    refute Map.has_key?(current.team.members, "lua-helper")

    assert {:ok, %{error: nil}} =
             lua(analyst, "return assert(agents.remove({input = {member = 'lua-helper'}}))")

    refute Map.has_key?(
             AgentExamples.Agents.research_team_inspect!(team.id).team.topology.nodes,
             "lua-helper"
           )

    assert {:ok, %{error: error}} =
             lua(analyst, "return assert(agents.remove({input = {member = 'reviewer'}}))")

    refute is_nil(error)

    assert Map.has_key?(
             AgentExamples.Agents.research_team_inspect!(team.id).team.members,
             :reviewer
           )
  end

  defp member(team, name) do
    {:ok, id} = Aikido.AgentServer.state(team.team.members[name], &{:ok, &1.id})

    team.team.topology.nodes[name].resource
    |> Ash.ActionInput.for_action(:inspect, %{agent: id})
    |> Ash.run_action!()
  end

  defp lua(record, script) do
    pid =
      case Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), record.id) do
        {:ok, pid} -> pid
        :error -> nil
      end

    {:ok, caller} =
      Aikido.AgentServer.state(
        pid,
        &{:ok,
         %{
           agent_id: &1.id,
           agent_resource: record.__struct__,
           parent: &1.parent,
           aikido: Aikido.Default
         }}
      )

    AgentExamples.AI.LuaSurface
    |> Ash.ActionInput.for_action(:eval, %{script: script}, context: %{aikido: caller})
    |> Ash.run_action()
  end

  test "tools are supplied per instance rather than declared on the agent" do
    first =
      track(
        snapshot_result(
          Agents.assistant_start!(
            AI.offline(%{
              tool_context: %{context: %{stamp_label: "first"}},
              tools: AI.Tools.for_assistant()
            })
          )
        )
      )

    second =
      track(
        snapshot_result(
          Agents.assistant_start!(
            AI.offline(%{
              tool_context: %{context: %{stamp_label: "second"}},
              tools: AI.Tools.for_assistant()
            })
          )
        )
      )

    assert {:ok, first_answer} = AI.ask(first, "hello")
    assert {:ok, second_answer} = AI.ask(second, "hello")
    assert first_answer =~ "first: hello"
    assert second_answer =~ "second: hello"
    assert {:error, _} = snapshot_result(Agents.assistant_start(%{tools: [%{}]}))

    assert {:error, _} =
             snapshot_result(Agents.assistant_start(%{tools: [{AI.Tools, :missing_action}]}))
  end

  # Commands return receipts; state assertions opt into a separate inspection.
  defp snapshot_result({:ok, %{resource: resource, id: id}}),
    do: resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action()

  defp snapshot_result({:error, _} = error), do: error

  defp snapshot_result(%{resource: resource, id: id}),
    do: resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action!()
end
