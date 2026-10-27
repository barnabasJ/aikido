defmodule AgentExamples.AITest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias AgentExamples.{Agents, AI}

  test "the intentionally failing example tool exposes its cause and recovery guidance" do
    {_tools, registry} =
      AshAi.build_tools_and_registry(otp_app: :agent_examples, tools: [:fail_example])

    assert {:error, message} = registry["fail_example"].(%{"input" => %{}}, %{})
    assert message =~ "example_tool_unavailable"
    assert message =~ "deliberately fails"
    assert message =~ "Repeating this call cannot succeed"
    refute message =~ "unknown_error"
    refute message =~ "unexpected error occurred"
  end

  test "both Lua tools distinguish VM failures from successful user data containing an error key" do
    {_tools, registry} =
      AshAi.build_tools_and_registry(
        otp_app: :agent_examples,
        tools: AI.Tools.for_lua() ++ [:scoped_lua]
      )

    for tool <- ["run_lua", "scoped_lua"],
        script <- [
          "local = invalid syntax",
          "error('explain this runtime failure')",
          "return missing_api({})"
        ] do
      assert {:error, content} = registry[tool].(%{"input" => %{"script" => script}}, %{})

      assert %{"code" => "lua_script_failed", "error" => details, "recovery" => recovery} =
               Jason.decode!(content)

      assert inspect(details) =~ "lua_error"
      assert recovery =~ "lua_docs"
      refute content =~ "unexpected error occurred"
    end

    assert {:ok, content, _raw} =
             registry["run_lua"].(
               %{"input" => %{"script" => "return {error = 'user data'}"}},
               %{}
             )

    assert %{"error" => nil, "result" => %{"error" => "user data"}} = Jason.decode!(content)
  end

  defmodule RuntimeClient do
    @behaviour Aikido.AiReact.Client
    def generate_text(%{probe: probe} = model, messages, options) do
      send(probe, {:runtime_model_call, model, messages, options})

      {:ok,
       %ReqLLM.Response{
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("runtime configured", tool_calls: []),
         finish_reason: :stop
       }}
    end
  end

  defmodule GatedClient do
    @behaviour Aikido.AiReact.Client
    def generate_text(%{probe: probe}, messages, _options) do
      send(probe, {:gated_model, self(), messages})

      receive do
        :finish ->
          {:ok,
           %ReqLLM.Response{
             id: "gated",
             model: "offline",
             context: ReqLLM.Context.new(),
             message: ReqLLM.Context.assistant("worker finished", tool_calls: []),
             finish_reason: :stop
           }}
      end
    end
  end

  defmodule RejectedClient do
    @behaviour Aikido.AiReact.Client
    def generate_text(_model, _messages, _options),
      do: {:error, "Provider rejected request (429)"}
  end

  defmodule FailingClient do
    @behaviour Aikido.AiReact.Client
    def generate_text(%{failure: failure}, _messages, _options), do: {:error, failure}
  end

  test "custom client failures without public protocols remain actionable and omit private terms" do
    {_tools, registry} =
      AshAi.build_tools_and_registry(otp_app: :agent_examples, tools: AI.Tools.for_lua())

    for failure <- [
          RuntimeError.exception("private-client-key"),
          {:transport_lost, "private-client-key"}
        ] do
      team =
        track(
          snapshot_result(
            start_team_with_members(
              AI.offline(%{
                client: FailingClient,
                model: %{failure: failure},
                tools: AI.Tools.for_lua()
              })
            )
          )
        )

      assert {:error, content} =
               run_team_lua_tool(
                 registry,
                 team,
                 "return assert(agents.delegate({input = {member = 'analyst', text = 'Test custom failure'}}))"
               )

      assert content =~ "team_operation_failed"
      assert content =~ "before retrying"
      refute content =~ "private-client-key"
      refute content =~ "unknown_error"
      refute content =~ "unexpected error occurred"
    end
  end

  test "native provider rejection reaches a Lua delegator with status and recovery instructions" do
    Req.Test.set_req_test_to_shared()
    owner = Ash.UUIDv7.generate()

    assert {:ok, _} =
             AgentExamples.Playground.configure_provider(owner, %{
               "mode" => "live",
               "provider" => "zai_coder",
               "model" => "glm-5.3-flash",
               "api_key" => "test-only"
             })

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{error: %{message: "private-provider-key", code: "rate_limit_exceeded"}})
    end)

    team =
      track(
        snapshot_result(
          start_team_with_members(%{
            model: %{provider: :zai_coder, id: "glm-5.3-flash", credential_owner: owner},
            client: AI.LiveClient,
            tools: AI.Tools.for_lua(),
            tool_options: [otp_app: :agent_examples],
            options: %{streaming: false},
            llm_opts: [
              req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
            ]
          })
        )
      )

    {_tools, registry} =
      AshAi.build_tools_and_registry(otp_app: :agent_examples, tools: AI.Tools.for_lua())

    assert {:error, content} =
             run_team_lua_tool(
               registry,
               team,
               "return assert(agents.delegate({input = {member = 'analyst', text = 'Test provider rejection'}}))"
             )

    assert content =~ "429"
    assert content =~ "quota"
    refute content =~ "private-provider-key"
    refute content =~ "unknown_error"
    refute content =~ "unexpected error occurred"

    current = Agents.research_team_inspect!(team.id)
    assert [task] = Map.values(current.team.tasks)
    assert %Aikido.AiReact.Errors.ProviderRequestFailed{status: 429} = task.result
    refute inspect(task.result) =~ "private-provider-key"

    {:ok, pid} = Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), team.id)

    {:ok, subscription} =
      Aikido.AgentServer.subscribe(
        pid,
        "ai.react.deliver",
        fn _runtime, event ->
          {:ok, event.signal.data.text}
        end,
        once: true
      )

    assert {:ok, %{mode: :background}} =
             AI.delegate(team, :analyst, "Background provider rejection", mode: :background)

    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, message}}}, 10_000
    assert message =~ "429"
    assert message =~ "quota"
    refute message =~ "private-provider-key"
    refute message =~ "unexpected error occurred"
  end

  defp run_team_lua_tool(registry, team, script) do
    registry["run_lua"].(
      %{"input" => %{"script" => script}},
      %{
        context: %{
          aikido: %{
            agent_id: team.id,
            agent_resource: team.__struct__,
            parent: nil,
            aikido: Aikido.Default
          }
        }
      }
    )
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
      record.__struct__
      |> Ash.ActionInput.for_action(:stop, %{agent: record})
      |> Ash.run_action()
    end)

    record
  end

  # Tests of existing-worker behavior declare their own initial topology.
  defp start_team_with_members(attributes) do
    attributes =
      Map.put_new(attributes, :topology, %{
        analyst: %{resource: AgentExamples.Researcher},
        reviewer: %{resource: AgentExamples.Reviewer}
      })

    Agents.research_team_start!(attributes)
  end

  test "research team starts alone and creates every worker dynamically" do
    team =
      track(
        snapshot_result(Agents.research_team_start!(AI.offline(%{tools: AI.Tools.for_team()})))
      )

    assert team.team.members == %{}
    assert team.team.topology.nodes == %{}

    assert {:ok, answer} = AI.ask(team, "orchestrate: Signals carry results")
    refute answer =~ "Tool error:"
    current = Agents.research_team_inspect!(team.id)

    assert Enum.sort(Map.keys(current.team.members)) == [
             "analyst",
             "analyst-helper",
             "reviewer",
             "specialist"
           ]

    assert current.team.topology.nodes["analyst-helper"].owner == "analyst"
  end

  test "model and tools are sufficient for real agents and teams" do
    for create <- [&Agents.assistant_start!/1, &start_team_with_members/1] do
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
    for create <- [&Agents.assistant_start!/1, &start_team_with_members/1] do
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
        start_team_with_members(
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

  test "background delegation returns while the worker is busy and delivers the correlated result" do
    team =
      track(
        snapshot_result(
          start_team_with_members(
            AI.offline(%{tools: [], model: %{probe: self()}, client: GatedClient})
          )
        )
      )

    {:ok, team_pid} =
      Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), team.id)

    {:ok, notice} =
      Aikido.AgentServer.subscribe(
        team_pid,
        "ai.react.deliver",
        &{:ok, &1.agent.state.ai.run_metadata},
        once: true
      )

    assert {:ok, %{error: nil}} =
             lua(
               team,
               "return assert(agents.delegate({input = {member = 'analyst', text = 'Background question', mode = 'background'}}))"
             )

    assert_receive {:gated_model, worker, _}, 5_000
    current = Agents.research_team_inspect!(team.id)
    assert [{id, task}] = Map.to_list(current.team.tasks)
    assert task.mode == :background
    assert task.status == :dispatched
    assert task.notify == :self
    send(worker, :finish)
    assert_receive {:aikido_subscription, ^notice, %{result: {:ok, metadata}}}, 5_000
    assert metadata.task.id == id
    assert metadata.task.status == :completed
    assert metadata.task.result == "worker finished"
  end

  test "a team waits for background evidence before reporting its final answer" do
    team =
      track(
        snapshot_result(
          start_team_with_members(
            AI.offline(%{
              tools: [],
              model: %{probe: self()},
              client: GatedClient,
              options: %{completion: :tasks}
            })
          )
        )
      )

    assert {:ok, receipt} = AI.delegate(team, :analyst, "Collect evidence", mode: :background)
    assert_receive {:gated_model, child, _}, 5_000

    {:ok, team_pid} =
      Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), team.id)

    {:ok, subscription} =
      Aikido.AgentServer.subscribe(
        team_pid,
        "ai.react.llm.completed",
        &{:ok, Map.take(&1.agent.state.ai, [:status, :request_id, :deadline_at])},
        once: true
      )

    waiter =
      Task.async(fn -> AI.ask(team, "Synthesize the delegated evidence", timeout: 10_000) end)

    assert_receive {:gated_model, first_turn, _}, 5_000
    send(first_turn, :finish)
    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, waiting}}}, 5_000
    assert waiting.status == :waiting
    waiter_ref = waiter.ref
    refute_received {^waiter_ref, _}

    send(child, :finish)
    assert_receive {:gated_model, synthesis, messages}, 5_000

    assert Enum.any?(messages, fn message ->
             Enum.any?(
               message.content,
               &(is_binary(&1.text) && String.contains?(&1.text, receipt.task_id))
             )
           end)

    send(synthesis, :finish)
    assert {:ok, "worker finished"} = Task.await(waiter, 5_000)
    {:ok, final} = Aikido.AgentServer.state(team_pid, &{:ok, &1.agent.state.ai})
    assert final.status == :completed
    assert final.request_id == waiting.request_id
    assert final.deadline_at == waiting.deadline_at
    assert final.iteration == 2
  end

  test "background results go to the requesting researcher, not its coordinator" do
    team =
      track(
        snapshot_result(
          start_team_with_members(
            AI.offline(%{tools: [], model: %{probe: self()}, client: GatedClient})
          )
        )
      )

    analyst = member(team, :analyst)

    {:ok, notice} =
      Aikido.AgentServer.subscribe(
        team.team.members.analyst,
        "ai.react.deliver",
        &{:ok, &1.agent.state.ai.run_metadata},
        once: true
      )

    assert {:ok, %{error: nil}} =
             lua(
               analyst,
               "return assert(agents.delegate({input = {member = 'reviewer', text = 'Check independently', mode = 'background'}}))"
             )

    assert_receive {:gated_model, worker, _}, 5_000
    [{id, task}] = Agents.research_team_inspect!(team.id).team.tasks |> Map.to_list()
    assert task.notify == :analyst
    send(worker, :finish)
    assert_receive {:aikido_subscription, ^notice, %{result: {:ok, metadata}}}, 5_000
    assert metadata.task.id == id
    assert metadata.task.result == "worker finished"
  end

  test "backgrounding foreground work releases its waiter without restarting or cancelling the worker" do
    team =
      track(
        snapshot_result(
          start_team_with_members(
            AI.offline(%{tools: [], model: %{probe: self()}, client: GatedClient})
          )
        )
      )

    waiter = Task.async(fn -> AI.delegate(team, :analyst, "Keep sorting") end)
    assert_receive {:gated_model, worker, _}, 5_000
    [{id, original}] = Agents.research_team_inspect!(team.id).team.tasks |> Map.to_list()
    assert original.mode == :foreground

    assert {:ok, %{error: nil}} =
             lua(
               team,
               "return assert(agents.delegate({input = {task_id = '#{id}', mode = 'background'}}))"
             )

    assert {:ok, %{task_id: ^id, mode: :background}} = Task.await(waiter, 5_000)
    assert Process.alive?(worker)
    changed = Agents.research_team_inspect!(team.id).team.tasks[id]
    assert changed.attempt == original.attempt
    assert changed.metadata == original.metadata
    assert changed.status == :dispatched

    {:ok, team_pid} =
      Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), team.id)

    {:ok, completion} =
      Aikido.AgentServer.subscribe(
        team_pid,
        "aikido.ash.team.task.completed",
        &{:ok, &1.agent.state.team.tasks[id]},
        once: true
      )

    send(worker, :finish)

    assert_receive {:aikido_subscription, ^completion,
                    %{result: {:ok, %{id: ^id, status: :completed}}}},
                   5_000

    assert map_size(Agents.research_team_inspect!(team.id).team.tasks) == 1
  end

  test "the team rejects a sibling wait cycle through Lua with an actionable error" do
    team =
      track(
        snapshot_result(
          start_team_with_members(
            AI.offline(%{tools: [], model: %{probe: self()}, client: GatedClient})
          )
        )
      )

    analyst = member(team, :analyst)
    reviewer = member(team, :reviewer)

    waiter =
      Task.async(fn ->
        lua(
          analyst,
          "return assert(agents.delegate({input = {member = 'reviewer', text = 'Review'}}))"
        )
      end)

    assert_receive {:gated_model, worker, _}, 5_000

    assert {:ok, %{error: error}} =
             lua(
               reviewer,
               "return assert(agents.delegate({input = {member = 'analyst', text = 'Analyze'}}))"
             )

    assert inspect(error) =~ "circular wait"
    assert inspect(error) =~ "background"
    assert map_size(Agents.research_team_inspect!(team.id).team.tasks) == 1
    send(worker, :finish)
    assert {:ok, %{error: nil}} = Task.await(waiter, 5_000)
  end

  test "delegation preserves the caller deadline and expired work is not dispatched" do
    team = track(start_team_with_members(AI.offline(%{tools: []})))
    deadline = System.system_time(:millisecond) + 600_000

    assert {:ok, _} = AI.delegate(team, :analyst, "Check the workflow", deadline_at: deadline)
    {:ok, worker} = Aikido.AgentServer.state(team.team.members.analyst, &{:ok, &1.agent.state.ai})
    assert worker.deadline_at == deadline
    assert worker.run_metadata.aikido_deadline_at == deadline

    started_at = System.system_time(:millisecond)

    assert {:ok, _} =
             AI.delegate(team, :analyst, "Use a smaller budget",
               deadline_at: deadline,
               timeout: 5_000
             )

    {:ok, capped} = Aikido.AgentServer.state(team.team.members.analyst, &{:ok, &1.agent.state.ai})
    assert capped.deadline_at >= started_at
    assert capped.deadline_at <= System.system_time(:millisecond) + 5_000
    assert capped.deadline_at < deadline

    before = Agents.research_team_inspect!(team.id).team.tasks

    assert {:error, :timeout} =
             AI.delegate(team, "analyst", "Must not dispatch", deadline_at: 1)

    assert Agents.research_team_inspect!(team.id).team.tasks == before
  end

  test "task-scoped workers stop only after their result reaches the team" do
    team = track(start_team_with_members(AI.offline(%{tools: []})))
    pid = team.team.members.analyst
    monitor = Process.monitor(pid)

    assert {:ok, _answer} =
             AI.delegate(team, :analyst, "One-off analysis", worker_lifecycle: :stop)

    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    current = Agents.research_team_inspect!(team.id)
    assert current.team.paused.analyst

    assert Enum.any?(current.team.tasks, fn {_, task} ->
             task.member == :analyst && task.status == :completed &&
               task.worker_lifecycle == :stop
           end)

    assert Process.alive?(current.team.members.reviewer)
  end

  test "Lua delegation exposes known provider failures instead of an opaque unknown error" do
    team =
      track(
        start_team_with_members(AI.offline(%{client: RejectedClient, tools: AI.Tools.for_lua()}))
      )

    assert {:ok, result} =
             lua(
               team,
               "return assert(agents.delegate({input = {member = 'analyst', text = 'Test failure'}}))"
             )

    assert inspect(result) =~ "Provider rejected request (429)"
    refute inspect(result) =~ "unknown_error"
  end

  test "Lua returned and raised errors survive the actual Ash AI callback as actionable JSON" do
    team =
      track(snapshot_result(start_team_with_members(AI.offline(%{tools: AI.Tools.for_lua()}))))

    analyst = member(team, :analyst)
    {:ok, pid} = Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), analyst.id)

    {:ok, caller} =
      Aikido.AgentServer.state(
        pid,
        &{:ok,
         %{
           agent_id: &1.id,
           agent_resource: analyst.__struct__,
           parent: Aikido.Ownership.parent(&1),
           aikido: Aikido.Default
         }}
      )

    {_, registry} =
      AshAi.build_tools_and_registry(otp_app: :agent_examples, tools: AI.Tools.for_lua())

    scripts = [
      "return agents.delegate({input = {member = 'analyst', text = 'Test'}})",
      "return assert(agents.delegate({input = {member = 'analyst', text = 'Test'}}))",
      "return agents.spawn({name = 'bad-shape'})",
      "return agents.remove({input = {name = 'analyst'}})"
    ]

    for script <- scripts do
      assert {:error, content} =
               registry["run_lua"].(%{"input" => %{"script" => script}}, %{
                 context: %{aikido: caller}
               })

      assert String.starts_with?(content, "{"), content
      assert %{"error" => %{"errors" => [error | _] = errors}} = Jason.decode!(content)
      assert Jason.decode!(content)["code"] == "lua_script_failed"
      assert Jason.decode!(content)["recovery"] =~ "Do not retry"
      assert is_binary(error["message"])
      refute Enum.any?(errors, &(&1["code"] == "unknown_error"))

      cond do
        script =~ "delegate" ->
          assert error["code"] == "self_delegation"
          assert error["message"] =~ "Perform this task directly"

        script =~ "remove" ->
          error = Enum.find(errors, &(&1["code"] == "no_such_input"))
          assert error
          assert error["code"] == "no_such_input"
          assert error["message"] =~ "name"
          assert error["fields"] == ["name"]
          assert Jason.decode!(content)["recovery"] =~ "lua_docs"

        true ->
          assert error["code"] == "invalid_input_shape"
          assert error["message"] =~ "input"
      end
    end
  end

  test "Lua spawn failures explain duplicate names and template limits" do
    team =
      track(snapshot_result(start_team_with_members(AI.offline(%{tools: AI.Tools.for_lua()}))))

    assert {:ok, %{error: nil}} =
             lua(team, "return agents.spawn({input = {name = 'one', template = 'squad'}})")

    assert {:ok, %{error: %{"errors" => [error]}}} =
             lua(team, "return agents.spawn({input = {name = 'one', template = 'squad'}})")

    assert error["code"] == "invalid_argument"
    assert error["message"] =~ "reuse"

    assert {:ok, %{error: nil}} =
             lua(team, "return agents.spawn({input = {name = 'two', template = 'squad'}})")

    assert {:ok, %{error: %{"errors" => [error]}}} =
             lua(team, "return agents.spawn({input = {name = 'three', template = 'squad'}})")

    assert error["code"] == "invalid_argument"
    assert error["message"] =~ "Reuse an existing worker"
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
          start_team_with_members(
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
    team = track(snapshot_result(start_team_with_members(AI.offline(%{tools: tools}))))
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
    team = track(snapshot_result(start_team_with_members(AI.offline(%{tools: tools}))))
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
      track(snapshot_result(start_team_with_members(AI.offline(%{tools: AI.Tools.for_lua()}))))

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
             String.trim(
               Ash.Resource.Info.attribute(AgentExamples.ResearchSquad, :system_prompt).default
             )

    refute squad.system_prompt == team.system_prompt

    assert {:ok, %{error: nil}} =
             lua(squad, "return assert(agents.spawn({input = {name = 'squad-worker'}}))")

    squad = AgentExamples.Agents.research_squad_inspect!(squad.id)
    assert Map.has_key?(squad.team.members, "squad-worker")

    refute Map.has_key?(
             AgentExamples.Agents.research_team_inspect!(team.id).team.members,
             "squad-worker"
           )

    assert {:ok, %{error: nil}} =
             lua(
               squad,
               "return assert(agents.spawn({input = {name = 'subteam', template = 'squad'}}))"
             )

    squad = Agents.research_squad_inspect!(squad.id)
    subteam = member(squad, "subteam")
    assert subteam.__struct__ == AgentExamples.ResearchSquad
    assert subteam.tools == team.tools

    assert {:ok, %{error: nil}} =
             lua(subteam, "return assert(agents.spawn({input = {name = 'specialist'}}))")

    subteam = Agents.research_squad_inspect!(subteam.id)
    assert Map.has_key?(subteam.team.members, "specialist")
    refute Map.has_key?(squad.team.members, "specialist")

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
           parent: Aikido.Ownership.parent(&1),
           aikido: Aikido.Default
         }}
      )

    AgentExamples.AI.LuaSurface
    |> Ash.ActionInput.for_action(:eval, %{script: script}, context: %{aikido: caller})
    |> Ash.run_action()
    |> case do
      {:ok, result} -> {:ok, Map.update!(result, :error, &AshLua.Encoder.encode_result/1)}
      error -> error
    end
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
