defmodule AgentExamplesWeb.LiveViewTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.{Catalog, Playground}
  @endpoint AgentExamplesWeb.Endpoint

  defmodule GatedClient do
    @behaviour Aikido.AiReact.Client
    def generate_text(%{probe: probe}, _messages, _options) do
      send(probe, {:waiting_worker, self()})

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

  setup do
    owner = Ash.UUIDv7.generate()
    Playground.subscribe(owner)
    %{conn: build_conn() |> Plug.Test.init_test_session(%{browser_id: owner})}
  end

  test "Lua controls match each example's supported tool modes", %{conn: conn} do
    optional = ~w(assistant hooks conversation hook-requests researcher reviewer)
    required = ~w(research-team lua-permissions)
    fixed = ~w(adaptive-tools verified-work verified-team resilience recovery)

    for slug <- optional ++ required ++ fixed do
      {:ok, view, _} = live(conn, "/examples/#{slug}")

      if slug in optional do
        assert has_element?(view, "#start-form input[type=checkbox][name=lua]")
        assert has_element?(view, "#start-form", "Enable Lua scripting tools")
      else
        refute has_element?(view, "#start-form input[type=checkbox][name=lua]")
      end

      if slug in required do
        assert has_element?(view, "#start-form input[type=hidden][name=lua][value=true]")
        assert has_element?(view, "#lua-required")
      else
        refute has_element?(view, "#lua-required")
      end

      GenServer.stop(view.pid)
    end
  end

  test "example tool policies are enforced when starting outside the form" do
    cases = [
      {"research-team", "false", [:text_stats, :stamp, :run_lua, :lua_docs]},
      {"lua-permissions", "false", [:scoped_lua, :scoped_lua_docs]},
      {"adaptive-tools", "true", []},
      {"verified-work", "true", [:record_evidence]},
      {"verified-team", "true", [:request_team_evidence, :complete_team_evidence]},
      {"resilience", "true", [:text_stats, :stamp, :fail_example]},
      {"assistant", "false", [:text_stats, :stamp]},
      {"assistant", "true", [:text_stats, :stamp, :run_lua, :lua_docs]}
    ]

    for {slug, lua, expected} <- cases do
      owner = Ash.UUIDv7.generate()
      {:ok, run} = Playground.start(owner, slug, %{"mode" => "offline", "lua" => lua})
      on_exit(fn -> Playground.stop(owner, slug) end)

      assert {:ok, ^expected} =
               Aikido.AgentServer.state(run.record.pid, fn runtime ->
                 {:ok, runtime.agent.state.ai.tools}
               end)

      assert :ok = Playground.stop(owner, slug)
    end
  end

  test "optional Lua examples complete tasks with scripting both enabled and disabled" do
    for slug <- ~w(assistant hooks conversation hook-requests researcher reviewer),
        lua <- ["true", "false"] do
      owner = Ash.UUIDv7.generate()
      {:ok, _run} = Playground.start(owner, slug, %{"mode" => "offline", "lua" => lua})
      on_exit(fn -> Playground.stop(owner, slug) end)
      assert :ok = Playground.command(owner, slug, :ask, %{query: "Signals carry results"})

      if slug == "hook-requests" do
        await(owner, slug, &(&1.requests != []))
        [request] = Playground.get(owner, slug).requests

        assert :ok =
                 Playground.command(owner, slug, :respond, %{
                   interaction_id: request.id,
                   response: %{choice: "approve"}
                 })
      end

      await(owner, slug, &(&1.status == :completed && &1.snapshot.ai.status == :completed))
      run = Playground.get(owner, slug)
      assert run.snapshot.ai.status == :completed
      assert Enum.any?(run.messages, &(&1.role == :assistant))
      assert :ok = Playground.stop(owner, slug)
    end
  end

  test "Aikido inspector keeps selectable state history without changing the live agent", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/counter")
    owner = start(view, "counter")
    assert has_element?(view, "#aikido-inspector")
    assert :ok = Playground.command(owner, "counter", :add, %{amount: 3})

    await(owner, "counter", fn run ->
      Enum.any?(run.inspection.entries, &(&1.after["state"]["count"] == 3))
    end)

    assert has_element?(view, "#inspector-content", "count")
    assert has_element?(view, "#inspector-content", "3")
    history = Playground.get(owner, "counter").inspection.entries
    entry = Enum.find(history, &(&1.execution.signal.type == "counter.add"))
    assert entry.before["state"]["count"] == 0
    assert entry.after["state"]["count"] == 3
    assert :ok = Playground.command(owner, "counter", :add, %{amount: 4})

    await(owner, "counter", fn run ->
      Enum.any?(run.inspection.entries, &(&1.after["state"]["count"] == 7))
    end)

    view
    |> element("#aikido-inspector button[phx-value-sequence='#{entry.sequence}']")
    |> render_click()

    view |> element("#aikido-inspector button[phx-value-view=after]") |> render_click()
    assert has_element?(view, "#inspector-content", "3")
    assert Playground.get(owner, "counter").snapshot.own.count == 7
    assert has_element?(view, "#inspector-content details.inspector-value")
    assert has_element?(view, "#inspector-content .inspector-number", "3")

    view |> element("#aikido-inspector button[phx-value-format=raw]") |> render_click()
    assert has_element?(view, "#inspector-content .syntax-highlight span")
    assert has_element?(view, "#inspector-content", "count")
    assert has_element?(view, "#definition-AgentExamples-Counter .syntax-highlight span")
    assert Playground.get(owner, "counter").snapshot.own.count == 7

    assert :ok = Playground.command(owner, "counter", :add, %{amount: 5})

    await(owner, "counter", fn run ->
      Enum.any?(run.inspection.entries, &(&1.after["state"]["count"] == 12))
    end)

    assert has_element?(
             view,
             "#aikido-inspector button[phx-value-sequence='#{entry.sequence}'][aria-pressed=true]"
           )

    assert has_element?(view, "#inspector-content .mi", "3")

    assert has_element?(
             view,
             ".inspector-agent[title='#{Playground.get(owner, "counter").record.id}']"
           )

    view |> element("#aikido-inspector button[phx-click=inspection_live]") |> render_click()
    assert has_element?(view, "#inspector-content .mi", "12")

    view |> form("#inspector-filter", filter: "no-such-signal") |> render_change()
    assert has_element?(view, "#aikido-inspector", "No matching signals.")
    refute has_element?(view, "#aikido-inspector button[phx-value-sequence]")
    view |> form("#inspector-filter", filter: "counter.add") |> render_change()
    assert has_element?(view, "#aikido-inspector button[phx-value-sequence='#{entry.sequence}']")

    {:ok, reloaded, _} = live(conn, "/examples/counter")

    assert has_element?(
             reloaded,
             "#aikido-inspector button[phx-value-sequence='#{entry.sequence}']"
           )
  end

  test "the index links to a descriptive LiveView page for every example", %{conn: conn} do
    {:ok, index, _} = live(conn, "/")

    for example <- Catalog.all() do
      assert has_element?(index, "#example-#{example.slug}", example.title)
      {:ok, page, html} = live(conn, "/examples/#{example.slug}")
      assert has_element?(page, "h1", example.title)
      assert has_element?(page, "#start-form")
      assert html =~ example.description
      assert has_element?(page, ".flow")
    end
  end

  test "each example has its own LiveView and shared navigation", %{conn: conn} do
    pages = [
      {"lua-permissions", AgentExamplesWeb.LuaPermissionsLive},
      {"adaptive-tools", AgentExamplesWeb.AdaptiveToolsLive},
      {"verified-work", AgentExamplesWeb.VerifiedWorkLive},
      {"verified-team", AgentExamplesWeb.VerifiedTeamLive},
      {"resilience", AgentExamplesWeb.ResilienceLive},
      {"recovery", AgentExamplesWeb.RecoveryLive},
      {"counter", AgentExamplesWeb.CounterLive},
      {"cron", AgentExamplesWeb.CronLive},
      {"checkpoint", AgentExamplesWeb.CheckpointLive},
      {"notifications", AgentExamplesWeb.NotificationsLive},
      {"checklist", AgentExamplesWeb.ChecklistLive},
      {"notebook", AgentExamplesWeb.NotebookLive},
      {"worker", AgentExamplesWeb.WorkerLive},
      {"quicksort", AgentExamplesWeb.QuicksortLive},
      {"team", AgentExamplesWeb.TeamLive},
      {"nested-teams", AgentExamplesWeb.NestedTeamsLive},
      {"assistant", AgentExamplesWeb.AssistantLive},
      {"hooks", AgentExamplesWeb.HooksLive},
      {"conversation", AgentExamplesWeb.ConversationLive},
      {"hook-requests", AgentExamplesWeb.HookRequestsLive},
      {"researcher", AgentExamplesWeb.ResearcherLive},
      {"reviewer", AgentExamplesWeb.ReviewerLive},
      {"research-team", AgentExamplesWeb.ResearchTeamLive}
    ]

    assert Enum.sort(Enum.map(pages, &elem(&1, 0))) ==
             Enum.sort(Enum.map(Catalog.all(), & &1.slug))

    for {slug, module} <- pages do
      assert {:ok, %{module: ^module} = view, _html} = live(conn, "/examples/#{slug}")
      assert has_element?(view, "nav[aria-label=Examples] a.active[href='/examples/#{slug}']")
      assert has_element?(view, "#definitions")
    end
  end

  test "an unknown example has no route", %{conn: conn} do
    assert conn |> get("/examples/unknown") |> response(404) =~ "Not Found"
  end

  test "source definitions distinguish native tool boundaries from reducers" do
    example = Catalog.find("resilience")
    definitions = AgentExamples.Source.for_example(example)

    tool =
      Enum.find(definitions, &(&1.module == AgentExamples.ResilientAssistant.Tools.RejectWork))

    assert tool.category == :tool
    assert tool.path =~ "resilient_assistant/tools/reject_work.ex"
    refute tool.open?
  end

  test "every example shows one source panel per definition with the requested defaults", %{
    conn: conn
  } do
    for example <- Catalog.all() do
      {:ok, view, _} = live(conn, "/examples/#{example.slug}")
      definitions = AgentExamples.Source.for_example(example)
      assert Enum.any?(definitions, &(&1.module == example.resource))
      assert length(Enum.uniq_by(definitions, & &1.id)) == length(definitions)

      if example.slug in ["team", "nested-teams", "research-team"] do
        for {module, category, open?} <- [
              {Aikido.Team.Slice, :slice, true},
              {Aikido.Team.Actions.Start, :action, false},
              {Aikido.Team.Actions.AssignTask, :action, false}
            ] do
          definition = Enum.find(definitions, &(&1.module == module))
          assert definition, "Missing #{inspect(module)} on #{example.slug}"
          assert definition.category == category
          assert definition.open? == open?
        end

        activation = Enum.find(definitions, &(&1.module == Aikido.Team.Types.Activation))
        assert activation
        refute activation.open?
      end

      if Catalog.ai?(example) do
        assert Enum.any?(definitions, &(&1.module == Aikido.AiReact.Types.Status))
      end

      for definition <- definitions do
        assert has_element?(view, "##{definition.id} summary", definition.name)
        assert has_element?(view, "##{definition.id} summary", definition.path)
        assert has_element?(view, "##{definition.id} code", "def") == definition.open?
        assert has_element?(view, "##{definition.id}[open]") == definition.open?
      end
    end

    worker = Catalog.find("worker") |> AgentExamples.Source.for_example()
    assert Enum.any?(worker, &(&1.module == AgentExamples.Worker.Types.Status))
    definition = Enum.find(worker, &(&1.module == AgentExamples.Worker))
    assert definition.code =~ "route AgentExamples.Worker.Signals.Run"

    assert String.replace(definition.code, ~r/\s+/, " ") =~
             "route AgentExamples.Worker.Signals.Completed, AgentExamples.Worker.Actions.Completed, public?: false"

    assert definition.code =~
             "route AgentExamples.Worker.Signals.Failed, AgentExamples.Worker.Actions.Failed, public?: false"

    refute definition.code =~ "argument :"
    assert definition.open?

    work = Enum.find(worker, &(&1.module == AgentExamples.Worker.Actions.Work))
    assert work.code =~ "use Ash.Resource.Actions.Implementation"
    assert work.code =~ "Aikido.Directives.async_task"
    assert work.path == "examples/agent_app/lib/agent_examples/worker/actions/work.ex"
    refute work.open?

    for {slug, module, path} <- [
          {"counter", AgentExamples.Counter.Actions.Increment, "counter/actions/increment.ex"},
          {"notebook", AgentExamples.Journal.Actions.AppendEntry,
           "journal/actions/append_entry.ex"}
        ] do
      definition =
        Catalog.find(slug)
        |> AgentExamples.Source.for_example()
        |> Enum.find(&(&1.module == module))

      assert definition.category == :action
      assert definition.path == "examples/agent_app/lib/agent_examples/" <> path
      refute definition.open?
    end

    signal = Enum.find(worker, &(&1.module == AgentExamples.Worker.Signals.Run))
    assert signal.category == :signal
    assert signal.code =~ "use Aikido.Signal"
    assert signal.code =~ "attribute :text, :string"
    assert signal.path == "examples/agent_app/lib/agent_examples/worker/signals/run.ex"
    refute signal.open?

    directive =
      Catalog.find("research-team")
      |> AgentExamples.Source.for_example()
      |> Enum.find(&(&1.module == Aikido.AiReact.Directives.LLMCall))

    assert directive.category == :directive
    assert directive.code =~ "use Aikido.Directive"
    assert directive.code =~ "typed_struct do"
    assert directive.code =~ "def exec("
    refute directive.open?

    research = Catalog.find("research-team") |> AgentExamples.Source.for_example()

    for {module, category} <- [
          {Aikido.AI, :support},
          {Aikido.AiReact.Options, :support},
          {Aikido.AiReact.HookQueue, :support},
          {Aikido.AiReact.Hooks.Hook, :support},
          {Aikido.AiReact.Directives.ExecuteHook, :directive},
          {Aikido.AiWorker.Signals.Accept, :signal},
          {Aikido.AiWorker.Actions.Accept, :action}
        ] do
      definition = Enum.find(research, &(&1.module == module))
      assert definition.category == category
      refute definition.open?
    end
  end

  test "counter commands update its visual and stop releases its process", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/counter")
    owner = start(view, "counter")
    view |> form("#counter-form", %{amount: "7"}) |> render_submit()
    await(owner, "counter", &(&1.snapshot.own.count == 7))
    assert has_element?(view, "#counter-value", "7")
    assert has_element?(view, "#events", "counter.add")
    record = Playground.get(owner, "counter").record
    view |> element("#stop-example") |> render_click()
    assert Playground.get(owner, "counter").status == :stopped

    assert (case Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), record.id) do
              {:ok, pid} -> pid
              :error -> nil
            end) == nil

    assert has_element?(view, "#start-form")
  end

  test "checklist and notebook controls change the appropriate state", %{conn: conn} do
    {:ok, checklist, _} = live(conn, "/examples/checklist")
    owner = start(checklist, "checklist")
    checklist |> form("#checklist-form", %{item: "Try LiveView"}) |> render_submit()
    await(owner, "checklist", &(&1.snapshot.own.items == ["Try LiveView"]))
    assert has_element?(checklist, "#checklist", "Try LiveView")
    assert has_element?(checklist, "#agent-state", ~s(items: ["Try LiveView"]))
    checklist |> element("button[phx-click=complete]") |> render_click()
    await(owner, "checklist", &(&1.snapshot.own.completed == 1))
    assert has_element?(checklist, "#completed-count", "1 completed")
    assert has_element?(checklist, "#agent-state", "completed: 1")
    refute has_element?(checklist, "#agent-state", "Try LiveView")

    {:ok, notebook, _} = live(conn, "/examples/notebook")
    owner = start(notebook, "notebook")
    notebook |> form("#notebook-form", %{text: "A slice owns this note"}) |> render_submit()
    await(owner, "notebook", &(&1.snapshot.journal == ["A slice owns this note"]))
    assert has_element?(notebook, "#journal", "A slice owns this note")
  end

  test "counter union controls and wildcard notices update the signal visual", %{conn: conn} do
    {:ok, view, html} = live(conn, "/examples/counter")
    assert html =~ "native Ash union"
    view |> element("#definition-AgentExamples-Counter-Actions-Adjust summary") |> render_click()

    view
    |> element("#definition-AgentExamples-Counter-Actions-CountAll summary")
    |> render_click()

    assert has_element?(
             view,
             "#definition-AgentExamples-Counter-Actions-Adjust code",
             "value"
           )

    assert has_element?(
             view,
             "#definition-AgentExamples-Counter-Actions-CountAll code",
             "signals_seen"
           )

    assert has_element?(
             view,
             "#definition-AgentExamples-Counter-Signals-Increase:not([open])"
           )

    owner = start(view, "counter")
    baseline = Playground.get(owner, "counter").snapshot.own.signals_seen
    view |> form("#counter-increase-form", %{amount: "9"}) |> render_submit()
    await(owner, "counter", &(&1.snapshot.own.count == 9))
    view |> form("#counter-decrease-form", %{amount: "4"}) |> render_submit()
    await(owner, "counter", &(&1.snapshot.own.count == 5))
    view |> element("#counter-notice") |> render_click()
    await(owner, "counter", &(&1.snapshot.own.signals_seen == baseline + 3))

    assert has_element?(view, "#counter-value", "5")
    assert has_element?(view, "#signals-seen", "#{baseline + 3} signals observed")
    assert has_element?(view, "#events", "counter.increase")
    assert has_element?(view, "#events", "counter.decrease")
    assert has_element?(view, "#events", "counter.notice")
  end

  test "background task results arrive without blocking the LiveView", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/worker")
    owner = start(view, "worker")
    view |> form("#worker-form", %{text: "hello browser"}) |> render_submit()
    await(owner, "worker", &(&1.snapshot.own.status == :completed))
    assert has_element?(view, "#worker-result", "HELLO BROWSER")
  end

  test "a fixed team shows live member state", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/team")
    owner = start(view, "team")
    assert has_element?(view, "#member-count", "3 members")
    view |> element("#team-add") |> render_click()
    await(owner, "team", &(&1.snapshot.children["counter"].own.count == 11))
    view |> element("#team-tree [data-node=counter]") |> render_click()
    assert has_element?(view, "#agent-details", "count: 11")
    view |> element("#agent-details button", "Close") |> render_click()
    refute has_element?(view, "#agent-details")
  end

  test "background button releases a foreground delegation without cancelling it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/research-team")
    owner = start(view, "research-team", %{mode: "offline", lua: "true"})
    run = Playground.get(owner, "research-team")

    assert :ok =
             Playground.command(owner, "research-team", :add_member, %{
               member: "waiting",
               template: :researcher,
               initial_state: %{model: %{probe: self()}, client: GatedClient, tools: []}
             })

    waiter =
      Task.async(fn ->
        AgentExamples.AI.delegate(run.record, "waiting", "Check the claim", ash: run.scope)
      end)

    assert_receive {:waiting_worker, worker}, 5_000

    await(
      owner,
      "research-team",
      &Enum.any?(&1.snapshot.tasks, fn task -> task[:mode] == :foreground end)
    )

    assert has_element?(view, "#tasks button", "Continue in background")
    view |> element("#tasks button", "Continue in background") |> render_click()
    assert {:ok, %{task_id: id, mode: :background}} = Task.await(waiter, 5_000)
    assert Process.alive?(worker)
    refute has_element?(view, "#tasks button", "Continue in background")
    send(worker, :finish)

    await(
      owner,
      "research-team",
      &Enum.any?(&1.snapshot.tasks, fn task -> task.id == id && task.status == :completed end)
    )

    assert has_element?(view, "#tasks", "worker finished")
  end

  test "the AI team page runs orchestration, Lua, and dynamic helpers", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/research-team")
    owner = start(view, "research-team", %{mode: "offline", lua: "true"})
    refute has_element?(view, "#team-tree [data-node=analyst]")
    refute has_element?(view, "#team-tree [data-node=reviewer]")

    view
    |> form("#prompt-form", %{query: "orchestrate: Signals carry results"})
    |> render_submit()

    await(owner, "research-team", &(&1.status == :completed), 30_000)
    assert has_element?(view, "#messages", "Words: 3")
    assert has_element?(view, "#messages", "Lua:")
    assert has_element?(view, "#team-tree [data-node=analyst-helper]")
    assert has_element?(view, "#member-count", "4 members")
    assert has_element?(view, ".inspector #tasks", "completed")
    assert has_element?(view, ".inspector #tasks + #signal-activity")
    assert has_element?(view, "#team-tree [data-agent=Orchestrator]", "Completed")
    view |> element("#team-tree [data-agent='Orchestrator / analyst']") |> render_click()
    assert has_element?(view, "#agent-details", "Model turns:")
    assert has_element?(view, "#agent-details", "Succeeded")
    view |> element("#agent-details button", "Focus on this branch") |> render_click()
    assert has_element?(view, "#team-tree [data-node=analyst-helper]")
    view |> element("#team-tree button", "Up one parent") |> render_click()

    {:ok, reloaded, _} = live(conn, "/examples/research-team")
    assert has_element?(reloaded, "#member-count", "4 members")
    assert has_element?(reloaded, "#messages", "Lua:")
    refute Playground.get("another-browser", "research-team")

    view
    |> form("#prompt-form", %{query: "orchestrate: Count this second task"})
    |> render_submit()

    await(
      owner,
      "research-team",
      &(&1.status == :completed && List.last(&1.messages).text =~ "Words: 4"),
      30_000
    )

    assert has_element?(view, "#member-count", "4 members")
    refute has_element?(view, "#agent-details [data-tool-status=failed]")
    refute has_element?(view, "#messages", "Tool error:")
  end

  test "the hooks page runs offline and shows applied context and script definitions", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/examples/hooks")
    assert html =~ "aikido.send_context"
    assert html =~ "tool_gate"
    owner = start(view, "hooks", %{mode: "offline", lua: "true"})
    view |> form("#prompt-form", %{query: "Signals carry results"}) |> render_submit()
    await(owner, "hooks", &(&1.status == :completed), 10_000)
    assert has_element?(view, "#hook-context", "Keep the answer concise")
    assert has_element?(view, "#events", "ai.react.hook.completed")
    run = Playground.get(owner, "hooks")
    assert run.snapshot.ai.hook_errors == []

    assert length(
             (run.record.resource
              |> Ash.ActionInput.for_action(:inspect, %{agent: run.record})
              |> Ash.run_action!()).hooks
           ) == 3

    view |> form("#prompt-form", %{query: "deny-tools for this task"}) |> render_submit()
    await(owner, "hooks", &(&1.status == :failed), 10_000)
    assert render(view) =~ "The example tool gate denied this run."
  end

  test "the conversation example streams, waits for todos and retains prior turns", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/conversation")
    owner = start(view, "conversation", %{mode: "offline"})
    view |> form("#todo-form", %{text: "Verify the answer"}) |> render_submit()
    view |> form("#prompt-form", %{query: "Remember this"}) |> render_submit()
    await(owner, "conversation", &(&1.snapshot.ai.status == :waiting), 10_000)
    assert has_element?(view, "#stream-output", "I remember 1 user messages")
    view |> element("#todos button[phx-click=todo_complete]") |> render_click()
    await(owner, "conversation", &(&1.status == :completed))
    assert has_element?(view, "#messages", "Remember this")
    view |> form("#prompt-form", %{query: "What came before?"}) |> render_submit()
    await(owner, "conversation", &(&1.status == :completed), 10_000)
    assert has_element?(view, "#messages", "I remember 2 user messages")
    assert has_element?(view, "#definition-Aikido-Todo-Slice[open]")
  end

  test "a Lua request can be answered from LiveView and the same script continues", %{conn: conn} do
    {:ok, view, html} = live(conn, "/examples/hook-requests")
    assert html =~ "aikido.request"
    owner = start(view, "hook-requests", %{mode: "offline", lua: "true"})
    view |> form("#prompt-form", %{query: "Signals carry results"}) |> render_submit()
    await(owner, "hook-requests", &(&1.requests != [] && &1.snapshot.ai.iteration == 0))
    [request] = Playground.get(owner, "hook-requests").requests
    assert has_element?(view, "#request-#{request.id}", "Allow this task to run?")
    assert Playground.get(owner, "hook-requests").snapshot.ai.iteration == 0
    assert Playground.get(owner, "hook-requests").status == :running

    assert {:error, :request_not_pending} =
             Playground.command("another-browser", "hook-requests", :respond, %{
               interaction_id: request.id,
               response: %{choice: "approve"}
             })

    # A new LiveView reconstructs the card from Playground state, outside the agent.
    {:ok, reconnected, _} = live(conn, "/examples/hook-requests")
    assert has_element?(reconnected, "#request-#{request.id}")

    reconnected
    |> element("button[phx-value-id='#{request.id}'][phx-value-choice=approve]")
    |> render_click()

    await(owner, "hook-requests", &(&1.status == :completed))
    assert has_element?(reconnected, "#hook-context", "Lua received the response: approve")
    refute has_element?(reconnected, "#request-#{request.id}")

    assert {:error, :request_not_pending} =
             Playground.command(owner, "hook-requests", :respond, %{
               interaction_id: request.id,
               response: %{choice: "deny"}
             })

    assert has_element?(reconnected, "#messages", "Words: 3")

    # Repeating the same task and its answer history must still require fresh permission.
    reconnected |> form("#prompt-form", %{query: "Signals carry results"}) |> render_submit()
    await(owner, "hook-requests", &(&1.requests != [] && &1.snapshot.ai.iteration == 0))
    [next_request] = Playground.get(owner, "hook-requests").requests
    refute next_request.id == request.id
    assert Playground.get(owner, "hook-requests").snapshot.ai.iteration == 0
    reconnected |> element("#hook-requests button[phx-value-choice=deny]") |> render_click()
    await(owner, "hook-requests", &(&1.status == :failed))
    assert render(reconnected) =~ "Lua chose to stop after the response."
  end

  test "cancelling a request closes the card without waiting for the hook timeout", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/hook-requests")
    owner = start(view, "hook-requests", %{mode: "offline", lua: "true"})
    view |> form("#prompt-form", %{query: "Signals carry results"}) |> render_submit()
    await(owner, "hook-requests", &(&1.requests != []))
    view |> element("#hook-requests button[phx-click=cancel_run]") |> render_click()
    await(owner, "hook-requests", &(&1.status == :failed && &1.requests == []))
    refute has_element?(view, "#hook-requests button[phx-click=respond]")
  end

  test "the application callback owns timeouts and caller-exit cleanup", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/hook-requests")
    owner = start(view, "hook-requests", %{mode: "offline"})
    view |> form("#prompt-form", %{query: "Wait for a response"}) |> render_submit()
    await(owner, "hook-requests", &(length(&1.requests) == 1))

    # The app can apply its own deadline without any Aikido timeout machinery.
    timeout =
      Task.async(fn ->
        Playground.request(
          {owner, "hook-requests"},
          %{type: "extra", payload: %{}},
          %{hook: "application"},
          20
        )
      end)

    assert {:error, :timeout} = Task.await(timeout)
    await(owner, "hook-requests", &(length(&1.requests) == 1))

    caller =
      spawn(fn ->
        Playground.request({owner, "hook-requests"}, %{type: "extra", payload: %{}}, %{
          hook: "application"
        })
      end)

    await(owner, "hook-requests", &(length(&1.requests) == 2))
    Process.exit(caller, :kill)
    await(owner, "hook-requests", &(length(&1.requests) == 1))
  end

  test "stopping the example closes its callback's pending UI card", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/hook-requests")
    owner = start(view, "hook-requests", %{mode: "offline"})
    view |> form("#prompt-form", %{query: "Wait for a response"}) |> render_submit()
    await(owner, "hook-requests", &(&1.requests != []))
    [request] = Playground.get(owner, "hook-requests").requests
    assert :ok = Playground.stop(owner, "hook-requests")
    assert %{status: :stopped, requests: []} = Playground.get(owner, "hook-requests")

    assert {:error, :request_not_pending} =
             Playground.command(owner, "hook-requests", :respond, %{
               interaction_id: request.id,
               response: %{choice: "approve"}
             })
  end

  test "nested teams expose fixed and dynamic subtrees and remove all descendants", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/nested-teams")
    owner = start(view, "nested-teams")
    assert has_element?(view, "#member-count", "2 members")
    assert has_element?(view, "#tree-form option", "home / counter (agent)")
    assert has_element?(view, "#tree-form option", "home / notebook (agent)")
    view |> element("button[phx-click=squad_add][phx-value-member=home]") |> render_click()

    await(
      owner,
      "nested-teams",
      &(&1.snapshot.children["home"].children["counter"].own.count == 11)
    )

    assert Playground.get(owner, "nested-teams").snapshot.children["home"].children["counter"].own.count ==
             11

    view |> element("#spawn-squad") |> render_click()
    await(owner, "nested-teams", &Map.has_key?(&1.snapshot.children, "squad-1"))
    assert has_element?(view, "#member-count", "3 members")
    squad = Playground.get(owner, "nested-teams").snapshot.children["squad-1"]
    monitors = Enum.map(squad.members, &{&1.pid, Process.monitor(&1.pid)})

    squad_pid =
      Enum.find(Playground.get(owner, "nested-teams").snapshot.members, &(&1.name == "squad-1")).pid

    squad_ref = Process.monitor(squad_pid)

    view |> element("button[phx-click=squad_add][phx-value-member=squad-1]") |> render_click()

    await(
      owner,
      "nested-teams",
      &(&1.snapshot.children["squad-1"].children["counter"].own.count == 11)
    )

    view |> element("#team-tree [data-agent='Team / squad-1 / counter']") |> render_click()
    assert has_element?(view, "#agent-details", "count: 11")
    view |> element("#agent-details button", "Close") |> render_click()
    refute has_element?(view, "#agent-details")

    view |> element("button[phx-click=remove_squad]") |> render_click()
    await(owner, "nested-teams", &(length(&1.snapshot.members) == 2))
    assert_receive {:DOWN, ^squad_ref, :process, ^squad_pid, _}, 5_000
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5_000)

    assert has_element?(view, "#team-tree [data-node=squad-1][aria-label='squad-1: Stopped']")
    view |> element("#team-tree [data-agent='Team / squad-1 / counter']") |> render_click()
    assert has_element?(view, "#agent-details", "count: 11")
    assert has_element?(view, "#agent-details", "Stopped")

    assert Playground.get(owner, "nested-teams").snapshot.children["home"].children["counter"].own.count ==
             11
  end

  test "retired subtree subscriptions cannot update a replacement at the same path", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/nested-teams")
    owner = start(view, "nested-teams")
    key = {owner, "nested-teams"}
    baseline = playground_subscriptions(key)

    spawn_squad = fn ->
      assert :ok =
               Playground.command(owner, "nested-teams", :add_member, %{
                 member: "again",
                 template: :squad
               })

      await(owner, "nested-teams", fn run ->
        child = run.snapshot.children["again"]

        child && map_size(child.children) == 3 &&
          map_size(playground_subscriptions(key)) == map_size(baseline) + 4
      end)
    end

    spawn_squad.()

    retired =
      Enum.filter(playground_subscriptions(key), fn {_, sub} ->
        List.first(sub.member || []) == "again"
      end)

    assert length(retired) == 4

    assert :ok = Playground.command(owner, "nested-teams", :remove_member, %{member: "again"})

    await(owner, "nested-teams", fn run ->
      run.snapshot.recorded_members["again"].alive == false
    end)

    assert map_size(playground_subscriptions(key)) == map_size(baseline)

    spawn_squad.()
    run = Playground.get(owner, "nested-teams")
    replacement = run.snapshot.children["again"]
    assert map_size(playground_subscriptions(key)) == map_size(baseline) + 4

    for {ref, _} <- retired do
      send(
        Playground,
        {:aikido_subscription, ref,
         %{result: {:ok, %{replacement | own: %{title: "stale"}}}, signal_type: "stale"}}
      )
    end

    assert Playground.get(owner, "nested-teams").snapshot.children["again"] == replacement
    assert :ok = Playground.stop(owner, "nested-teams")
    assert playground_subscriptions(key) == %{}
  end

  defp playground_subscriptions(key) do
    Playground
    |> :sys.get_state()
    |> Map.fetch!(:subscriptions)
    |> Map.filter(fn {_, sub} -> sub.key == key end)
  end

  test "one tree mixes agent-owned agents and teams with recursively nested dynamic teams", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/nested-teams")
    owner = start(view, "nested-teams")

    spawn = fn path, kind, name ->
      view
      |> form("#tree-form", %{parent: Jason.encode!(path), kind: kind, name: name})
      |> render_submit()

      await(owner, "nested-teams", fn run ->
        Enum.any?(Playground.tree_options(run), fn {_, encoded} ->
          List.last(Jason.decode!(encoded)) == name
        end)
      end)

      render(view)
    end

    spawn.(["lead"], "agent", "helper")
    spawn.(["helper"], "team", "branch")
    spawn.(["branch"], "team", "inner")
    spawn.(["branch", "inner"], "team", "deeper")
    spawn.(["home"], "agent", "home-worker")
    spawn.(["home", "counter"], "agent", "counter-helper")

    snapshot = Playground.get(owner, "nested-teams").snapshot
    assert Enum.find(snapshot.members, &(&1.name == "helper")).owner == "lead"
    assert Enum.find(snapshot.members, &(&1.name == "branch")).owner == "helper"
    assert snapshot.children["branch"].children["inner"].children["deeper"].team?
    assert snapshot.children["home"].children["home-worker"].resource == AgentExamples.Worker

    assert Enum.find(snapshot.children["home"].members, &(&1.name == "counter-helper")).owner ==
             "counter"

    assert has_element?(view, "#team-tree [data-node=inner]")
    refute has_element?(view, "#team-tree [data-node=deeper]")
    view |> element("#team-tree [data-node=branch]") |> render_click()
    view |> element("#agent-details button", "Focus on this branch") |> render_click()
    assert has_element?(view, "#team-tree [data-node=deeper]")

    refs = Enum.map(tree_pids(snapshot), &{&1, Process.monitor(&1)})
    view |> element("#stop-example") |> render_click()
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5_000)
  end

  test "spawn errors stay visible and parent selections survive tree updates", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/nested-teams")
    owner = start(view, "nested-teams")
    input = %{parent: Jason.encode!(["lead"]), kind: "agent", name: "invalid name"}
    view |> form("#tree-form", input) |> render_change()
    view |> form("#tree-form", input) |> render_submit()
    assert has_element?(view, "#error")

    assert has_element?(view, "#tree-form option[selected]", "lead (agent)")
    assert length(Playground.get(owner, "nested-teams").snapshot.members) == 2
  end

  test "successful spawning clears the name and duplicate names have an actionable error", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/nested-teams")
    owner = start(view, "nested-teams")
    input = %{parent: Jason.encode!(["home"]), kind: "agent", name: "home-worker"}
    view |> form("#tree-form", input) |> render_submit()

    await(
      owner,
      "nested-teams",
      &Map.has_key?(&1.snapshot.children["home"].children, "home-worker")
    )

    assert has_element?(view, "#tree-form input[name=name][value='']")
    assert has_element?(view, "#tree-form option[selected]", "home (team)")

    view |> form("#tree-form", input) |> render_submit()
    assert has_element?(view, "#error", "already exists in this team. Choose another name.")
    refute render(view) =~ "Execution Error"
    assert has_element?(view, "#tree-form input[name=name][value=home-worker]")
    assert length(Playground.get(owner, "nested-teams").snapshot.children["home"].members) == 4

    view |> form("#tree-form", %{input | name: "another-worker"}) |> render_submit()

    await(
      owner,
      "nested-teams",
      &Map.has_key?(&1.snapshot.children["home"].children, "another-worker")
    )

    refute has_element?(view, "#error")
  end

  defp tree_pids(snapshot) do
    Enum.map(snapshot.members, & &1.pid) ++
      Enum.flat_map(snapshot.children, fn {_, child} -> tree_pids(child) end)
  end

  test "AI creation controls accept an external prompt and iteration limit", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/research-team")

    owner =
      start(view, "research-team", %{
        mode: "offline",
        system_prompt: "User-provided orchestration",
        max_iterations: "4"
      })

    reference = Playground.get(owner, "research-team").record

    record =
      reference.resource
      |> Ash.ActionInput.for_action(:inspect, %{agent: reference})
      |> Ash.run_action!()

    assert record.system_prompt == "User-provided orchestration"
    assert record.max_iterations == 4

    assert {:ok, %{system_prompt: "User-provided orchestration", max_iterations: 4}} =
             Aikido.AgentServer.state(
               case Aikido.Durable.lookup(
                      Aikido.durable_supervisor_name(Aikido.Default),
                      record.id
                    ) do
                 {:ok, pid} -> pid
                 :error -> nil
               end,
               &{:ok, Map.take(&1.agent.state.ai, [:system_prompt, :max_iterations])}
             )
  end

  test "the shared provider form validates live settings before starting an example", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/assistant")
    view |> form("#provider-form", %{mode: "live"}) |> render_change()

    view
    |> form("#provider-form", %{mode: "live", provider: "zai", model: "glm-5.3", api_key: ""})
    |> render_submit()

    assert has_element?(view, "#error", "Enter an API key")
  end

  test "provider settings and a hidden key are shared across every AI example", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/assistant")
    view |> form("#provider-form", %{mode: "live"}) |> render_change()

    view
    |> form("#provider-form", %{
      mode: "live",
      provider: "zai",
      model: "glm-5.3",
      api_key: "test-only-browser-key"
    })
    |> render_submit()

    assert has_element?(view, "#provider-saved")
    refute render(view) =~ "test-only-browser-key"

    for example <- Enum.filter(Catalog.all(), &Catalog.ai?/1) do
      {:ok, page, _} = live(conn, "/examples/#{example.slug}")
      assert has_element?(page, "#provider-form option[value=zai][selected]")
      assert has_element?(page, "#provider-form input[name=api_key][type=password][value='']")
      owner = start(page, example.slug)
      run = Playground.get(owner, example.slug)
      assert run.mode == "live"
      assert has_element?(page, "#active-model", "zai:glm-5.3")

      assert {:ok,
              %{client: AgentExamples.AI.LiveClient, model: %{provider: :zai, id: "glm-5.3"}}} =
               Aikido.AgentServer.state(run.record.pid, &{:ok, &1.agent.state.ai})

      dumped = Aikido.Durable.AgentServer.dump_state(:sys.get_state(run.record.pid).user_state)
      restored = Aikido.Durable.AgentServer.load_state(1, dumped)
      refute inspect(restored, limit: :infinity) =~ "test-only-browser-key"
      refute inspect(run, limit: :infinity) =~ "test-only-browser-key"

      for member <- run.snapshot.members do
        assert {:ok, AgentExamples.AI.LiveClient} =
                 Aikido.AgentServer.state(member.pid, &{:ok, &1.agent.state.ai.client})
      end
    end
  end

  test "browser assets are served locally without a Node build", %{conn: conn} do
    for path <- [
          "/assets/app.js",
          "/assets/app.css",
          "/vendor/phoenix/phoenix.mjs",
          "/vendor/live_view/phoenix_live_view.esm.js"
        ] do
      assert conn |> get(path) |> response(200) |> byte_size() > 0
    end
  end

  test "tool setup can be refreshed and receive queued messages before the first model turn", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/adaptive-tools")
    owner = start(view, "adaptive-tools")
    assert :ok = Playground.command(owner, "adaptive-tools", :ask, %{query: "first"})
    await(owner, "adaptive-tools", &(&1.snapshot.ai.status == :setup))
    view |> element("button[phx-value-set=stamp]") |> render_click()

    assert :ok =
             Playground.command(owner, "adaptive-tools", :ask, %{query: "queued during setup"})

    await(owner, "adaptive-tools", &(&1.status == :completed))
    run = Playground.get(owner, "adaptive-tools")
    assert run.snapshot.ai.tools_generation == 2
    assert List.last(run.messages).text =~ "Prepared tools: stamp"
    assert List.last(run.messages).text =~ "refreshed"
    assert has_element?(view, "#tool-refresh")
  end

  test "background evidence completes its required todo through a normal scoped tool", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/verified-team")
    owner = start(view, "verified-team")

    assert :ok =
             Playground.command(owner, "verified-team", :ask, %{
               query: "Check background result delivery"
             })

    await(owner, "verified-team", &(&1.snapshot.ai.status == :waiting))
    waiting = Playground.get(owner, "verified-team")
    refute waiting.snapshot.ai.todo_verification_pending
    assert waiting.snapshot.ai.todo_continuations == 0

    assert {:ok, waiting_ai} =
             Aikido.AgentServer.state(waiting.record.pid, &{:ok, &1.agent.state.ai})

    request_id = waiting_ai.request_id
    await(owner, "verified-team", &(&1.status == :completed))
    completed = Playground.get(owner, "verified-team")

    assert {:ok, completed_ai} =
             Aikido.AgentServer.state(completed.record.pid, &{:ok, &1.agent.state.ai})

    assert completed_ai.request_id == request_id
    assert List.last(completed.messages).text =~ "worker's evidence"

    assert Enum.any?(
             completed_ai.run_metadata.deliveries,
             &(get_in(&1, [:metadata, :task, :status]) == :completed)
           )

    assert [%{status: :completed, result: %{task_id: task_id, member: :evidence, result: result}}] =
             completed.snapshot.todos

    assert is_binary(task_id)
    assert result =~ "Evidence checked:"
    refute Enum.any?(completed.events, &(&1.type == "ai.react.todos.verified"))
  end

  test "delivered todo work is verified only after the evidence tool completes it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/verified-work")
    owner = start(view, "verified-work")
    view |> element("#deliver-work") |> render_click()
    await(owner, "verified-work", &(&1.status == :completed))
    run = Playground.get(owner, "verified-work")
    assert run.snapshot.ai.todo_continuations == 1

    assert [%{id: "delivered-work", status: :completed, result: "Checked by the evidence tool"}] =
             run.snapshot.todos

    assert List.last(run.messages).text =~ "Verified evidence"
    assert Enum.any?(run.events, &(&1.type == "ai.react.todos.verified"))
    assert has_element?(view, "#verified-answer", "Verified evidence")
  end

  test "real Ash AI errors and alternating calls trigger their optional guards", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/resilience")
    owner = start(view, "resilience")

    for {query, error} <- [
          {"cycle", {:tool_cycle_limit, 2, 5}},
          {"errors", {:tool_error_limit, 2}}
        ] do
      view |> element("#scenario-#{query}") |> render_click()
      await(owner, "resilience", &(&1.status == :failed && &1.snapshot.ai.error == error))
      assert Playground.get(owner, "resilience").snapshot.ai.error == error
    end
  end

  test "retry exhaustion and cancellation finish their waiters without blocking the page", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/resilience")
    owner = start(view, "resilience")
    view |> element("#scenario-retry") |> render_click()
    await(owner, "resilience", &(&1.status == :failed && &1.snapshot.ai.error == :timeout))
    assert Playground.get(owner, "resilience").snapshot.ai.error == :timeout
    view |> element("#scenario-wait") |> render_click()
    await(owner, "resilience", &(&1.snapshot.ai.status == :running))
    view |> element("#cancel-run") |> render_click()
    await(owner, "resilience", &(&1.status == :failed && &1.snapshot.ai.error == :cancelled))
    assert Playground.get(owner, "resilience").snapshot.ai.error == :cancelled
  end

  test "stopping and starting a permanent example restores its history under the same identity",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/recovery")
    owner = start(view, "recovery")
    assert :ok = Playground.command(owner, "recovery", :ask, %{query: "remember"})
    await(owner, "recovery", &(&1.status == :completed))
    previous = Playground.get(owner, "recovery").record
    view |> element("#stop-example") |> render_click()
    assert has_element?(view, "#start-form")
    start(view, "recovery")
    restored = Playground.get(owner, "recovery").record
    assert restored.id == previous.id
    assert restored.pid != previous.pid
    assert :ok = Playground.command(owner, "recovery", :ask, %{query: "recall"})
    await(owner, "recovery", &(&1.status == :completed))
    assert List.last(Playground.get(owner, "recovery").messages).text =~ "2 user messages"
    assert {:ok, _} = AgentExamples.Agents.recoverable_delete(restored)
  end

  test "Lua eval and docs use the same runtime entrypoints and retain the original scope", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/lua-permissions")
    owner = start(view, "lua-permissions")
    view |> element("#allow-scope") |> render_click()

    assert :ok =
             Playground.command(owner, "lua-permissions", :ask, %{
               query: "return session.whoami()"
             })

    await(owner, "lua-permissions", &(&1.status == :completed))

    answer =
      Playground.get(owner, "lua-permissions").messages
      |> List.last()
      |> Map.fetch!(:text)
      |> Jason.decode!()

    assert answer["result"] == %{"actor" => %{"id" => owner}, "tenant" => "playground"}
    view |> element("#deny-scope") |> render_click()
    assert :ok = Playground.command(owner, "lua-permissions", :ask, %{query: "docs"})
    await(owner, "lua-permissions", &(&1.status == :completed))
    refute List.last(Playground.get(owner, "lua-permissions").messages).text =~ "session.whoami"

    assert :ok =
             Playground.command(owner, "lua-permissions", :ask, %{
               query: "return session.whoami()"
             })

    await(owner, "lua-permissions", &(&1.status == :completed))

    answer =
      Playground.get(owner, "lua-permissions").messages
      |> List.last()
      |> Map.fetch!(:text)
      |> Jason.decode!()

    assert answer["error"]
    assert answer["result"] == nil
  end

  test "recursive quicksort renders the real tree and sorted result", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/quicksort")
    owner = start(view, "quicksort")
    GenServer.stop(view.pid)
    {:ok, view, _} = live(conn, "/examples/quicksort")
    view |> form("#quicksort-form", %{size: "32"}) |> render_submit()
    await(owner, "quicksort", &(&1.snapshot.own.status == :completed), 15_000)
    assert Playground.get(owner, "quicksort").snapshot.own.result == Enum.to_list(1..32)
    assert has_element?(view, "#sorting-tree #sort-metrics")
    assert has_element?(view, ".sort-visualization .sort-sidebar > #sort-depth-breakdown")
    assert has_element?(view, ".sort-sidebar > #sort-depth-breakdown + #signal-activity")
    refute has_element?(view, ".inspector #signal-activity")

    branch =
      if has_element?(view, "button[phx-click=focus][phx-value-branch=rootL]"),
        do: "rootL",
        else: "rootR"

    view |> element("button[phx-click=focus][phx-value-branch=#{branch}]") |> render_click()
    view |> element(".sort-navigation button", "Up one parent") |> render_click()
    assert has_element?(view, "#sorting-tree p", "Showing up to 80 nodes beneath root.")
    assert has_element?(view, ".sort-navigation button[disabled]", "Up one parent")

    assert has_element?(view, "#sort-result summary", "Sorted 32 values")
    assert has_element?(view, ".sort-diagram circle[data-status=completed]")
    GenServer.stop(view.pid)
    {:ok, reconnected, _} = live(conn, "/examples/quicksort")
    render_async(reconnected, 15_000)
    assert has_element?(reconnected, "#sort-spawned", "32 agents spawned")
    assert has_element?(reconnected, ".sort-diagram circle[data-status=completed]")

    old_id = Playground.get(owner, "quicksort").record.id
    old_topic = Playground.get(owner, "quicksort").snapshot.own.topic

    old_tree =
      Aikido.Default
      |> Aikido.durable_supervisor_name()
      |> Aikido.Durable.members()
      |> Enum.filter(fn {id, _} -> id == old_id || String.starts_with?(id, old_id <> "/") end)

    assert length(old_tree) in 1..32
    reconnected |> element("button[phx-click=restart_sort]") |> render_click()
    render_async(reconnected, 15_000)
    assert Playground.get(owner, "quicksort").snapshot.own.status == :idle
    refute Playground.get(owner, "quicksort").record.id == old_id
    assert Enum.all?(old_tree, fn {_, pid} -> !Process.alive?(pid) end)
    assert has_element?(reconnected, "#sort-spawned", "0 agents spawned")

    reconnected |> form("#quicksort-form", %{size: "32"}) |> render_submit()
    await(owner, "quicksort", &(&1.snapshot.own.status == :completed), 15_000)
    assert Playground.get(owner, "quicksort").snapshot.own.topic != old_topic

    send(
      reconnected.pid,
      {:quicksort_progress, old_topic, %{branch: "stale", status: :completed}}
    )

    send(reconnected.pid, :flush_quicksort_progress)
    assert has_element?(reconnected, "#sort-spawned", "32 agents spawned")
  end

  test "quicksort can restart after its root has already stopped", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/quicksort")
    owner = start(view, "quicksort")
    old = Playground.get(owner, "quicksort").record
    AgentExamples.Agents.quicksort_stop!(old)

    view |> element("button[phx-click=restart_sort]") |> render_click()
    render_async(view, 15_000)

    fresh = Playground.get(owner, "quicksort")
    refute fresh.record.id == old.id
    assert fresh.record.pid != old.pid
    assert Process.alive?(fresh.record.pid)
    assert fresh.snapshot.own.status == :idle
  end

  test "a stopped quicksort history is released when a reconnected browser starts again", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/quicksort")
    owner = start(view, "quicksort")
    view |> form("#quicksort-form", %{size: "32"}) |> render_submit()
    await(owner, "quicksort", &(&1.snapshot.own.status == :completed), 15_000)
    topic = Playground.get(owner, "quicksort").snapshot.own.topic
    assert {:ok, _tree} = AgentExamples.Quicksort.RunHistory.fetch(topic)
    assert :ok = Playground.stop(owner, "quicksort")
    GenServer.stop(view.pid)

    {:ok, reconnected, _} = live(conn, "/examples/quicksort")
    start(reconnected, "quicksort")

    assert :error = AgentExamples.Quicksort.RunHistory.fetch(topic)
  end

  test "starting a stopped quicksort retires a replacement PID for the same identity", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples/quicksort")
    owner = start(view, "quicksort")
    old = Playground.get(owner, "quicksort").record
    assert :ok = Playground.stop(owner, "quicksort")
    replacement = AgentExamples.Agents.quicksort_start!(%{id: old.id})
    monitor = Process.monitor(replacement.pid)
    detached = AgentExamples.Agents.quicksort_start!(%{id: old.id <> "/partition/42"})
    detached_monitor = Process.monitor(detached.pid)
    on_exit(fn -> AgentExamples.Agents.quicksort_stop(detached) end)
    independent = AgentExamples.Agents.quicksort_start!(%{})
    on_exit(fn -> AgentExamples.Agents.quicksort_stop(independent) end)

    start(view, "quicksort")

    assert_receive {:DOWN, ^monitor, :process, _, _}, 5000
    assert_receive {:DOWN, ^detached_monitor, :process, _, _}, 5000
    fresh = Playground.get(owner, "quicksort")
    refute fresh.record.id == old.id
    assert fresh.record.pid != replacement.pid
    assert Process.alive?(fresh.record.pid)
    assert Process.alive?(independent.pid)
    assert fresh.snapshot.own.status == :idle
    refute render(view) =~ "already_started"

    view |> form("#quicksort-form", %{size: "32"}) |> render_submit()
    await(owner, "quicksort", &(&1.snapshot.own.status == :completed), 15_000)
    assert Playground.get(owner, "quicksort").snapshot.own.result == Enum.to_list(1..32)
  end

  test "quicksort coalesces progress bursts without regressing terminal nodes", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/quicksort")
    owner = start(view, "quicksort")
    view |> form("#quicksort-form", %{size: "1"}) |> render_submit()
    await(owner, "quicksort", &(&1.snapshot.own.status == :completed), 15_000)
    topic = Playground.get(owner, "quicksort").snapshot.own.topic
    node = %{branch: "rootL", id: "display-test", status: :completed, count: 1, pivot: 1}
    send(view.pid, {:quicksort_progress, topic, node})
    for _ <- 1..1000, do: send(view.pid, {:quicksort_progress, topic, %{node | status: :idle}})
    send(view.pid, :flush_quicksort_progress)
    assert has_element?(view, "#sort-spawned", "2 agents spawned")

    assert has_element?(
             view,
             ".sort-diagram g[phx-value-branch=rootL] circle[data-status=completed]"
           )
  end

  defp start(view, slug, options \\ %{}) do
    view |> form("#start-form", options) |> render_submit()
    render_async(view, 15_000)
    assert_receive {:run_updated, owner, ^slug}, 5_000
    on_exit(fn -> Playground.stop(owner, slug) end)
    owner
  end

  defp await(owner, slug, predicate, timeout \\ 5_000) do
    Playground.subscribe(owner)
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(owner, slug, predicate, deadline)
  end

  defp wait(owner, slug, predicate, deadline) do
    if predicate.(Playground.get(owner, slug)) do
      :ok
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:run_updated, ^owner, ^slug} -> wait(owner, slug, predicate, deadline)
      after
        remaining ->
          flunk("Timed out waiting for #{slug}: #{inspect(Playground.get(owner, slug))}")
      end
    end
  end
end
