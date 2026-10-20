defmodule AgentExamplesWeb.LiveViewTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.{Catalog, Playground}
  @endpoint AgentExamplesWeb.Endpoint

  setup do
    Playground.subscribe()
    %{conn: build_conn() |> Plug.Test.init_test_session(%{browser_id: Ash.UUIDv7.generate()})}
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
      {"counter", AgentExamplesWeb.CounterLive},
      {"checklist", AgentExamplesWeb.ChecklistLive},
      {"notebook", AgentExamplesWeb.NotebookLive},
      {"worker", AgentExamplesWeb.WorkerLive},
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
              {Aikido.Ash.Team.State, :slice, true},
              {Aikido.Ash.Team.Actions.Start, :action, false},
              {Aikido.Ash.Team.Actions.AssignTask, :action, false}
            ] do
          definition = Enum.find(definitions, &(&1.module == module))
          assert definition, "Missing #{inspect(module)} on #{example.slug}"
          assert definition.category == category
          assert definition.open? == open?
        end
      end

      for definition <- definitions do
        assert has_element?(view, "##{definition.id} summary", definition.name)
        assert has_element?(view, "##{definition.id} summary", definition.path)
        assert has_element?(view, "##{definition.id} code", "def")
        assert has_element?(view, "##{definition.id}[open]") == definition.open?
      end
    end

    worker = Catalog.find("worker") |> AgentExamples.Source.for_example()
    definition = Enum.find(worker, &(&1.module == AgentExamples.Worker))
    assert definition.code =~ "route AgentExamples.Worker.Signals.Run"

    assert definition.code =~
             "route AgentExamples.Worker.Signals.Completed, AgentExamples.Worker.Completed, public?: false"

    assert definition.code =~
             "route AgentExamples.Worker.Signals.Failed, AgentExamples.Worker.Failed, public?: false"

    refute definition.code =~ "argument :"
    assert definition.open?

    work = Enum.find(worker, &(&1.module == AgentExamples.Worker.Work))
    assert work.code =~ "use Ash.Resource.Actions.Implementation"
    assert work.code =~ "Aikido.Directives.async_task"
    assert work.path == "examples/agent_app/lib/agent_examples/worker/work.ex"
    refute work.open?

    for {slug, module, path} <- [
          {"counter", AgentExamples.Counter.Increment, "counter/increment.ex"},
          {"notebook", AgentExamples.Journal.AppendEntry, "journal/append_entry.ex"}
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
      |> Enum.find(&(&1.module == Aikido.Slices.AiReact.Directives.LLMCall))

    assert directive.category == :directive
    assert directive.code =~ "use Aikido.Directive"
    assert directive.code =~ "typed_struct do"
    assert directive.code =~ "def exec("
    refute directive.open?

    research = Catalog.find("research-team") |> AgentExamples.Source.for_example()

    for {module, category} <- [
          {Aikido.AI, :support},
          {Aikido.Slices.AiReact.Options, :support},
          {Aikido.Slices.AiReact.Hooks, :support},
          {Aikido.Slices.AiReact.Hooks.Hook, :support},
          {Aikido.Slices.AiReact.Directives.ExecuteHook, :directive},
          {Aikido.Slices.AiWorker.Signals.Accept, :signal},
          {Aikido.Slices.AiWorker.Accept, :action}
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
    checklist |> element("button[phx-click=complete]") |> render_click()
    await(owner, "checklist", &(&1.snapshot.own.completed == 1))
    assert has_element?(checklist, "#completed-count", "1 completed")

    {:ok, notebook, _} = live(conn, "/examples/notebook")
    owner = start(notebook, "notebook")
    notebook |> form("#notebook-form", %{text: "A slice owns this note"}) |> render_submit()
    await(owner, "notebook", &(&1.snapshot.journal == ["A slice owns this note"]))
    assert has_element?(notebook, "#journal", "A slice owns this note")
  end

  test "counter union controls and wildcard notices update the signal visual", %{conn: conn} do
    {:ok, view, html} = live(conn, "/examples/counter")
    assert html =~ "native Ash union"
    assert has_element?(view, "#definition-AgentExamples-Counter-Adjust code", "%Ash.Union")
    assert has_element?(view, "#definition-AgentExamples-Counter-CountAll code", "signals_seen")

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
    assert has_element?(view, ".member-state", "count: 11")
  end

  test "the AI team page runs orchestration, Lua, and dynamic helpers", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/research-team")
    owner = start(view, "research-team", %{mode: "offline", lua: "true"})
    assert has_element?(view, "#member-count", "2 members")

    view
    |> form("#prompt-form", %{query: "orchestrate: Signals carry results"})
    |> render_submit()

    await(owner, "research-team", &(&1.status == :completed), 30_000)
    assert has_element?(view, "#messages", "Words: 3")
    assert has_element?(view, "#messages", "Lua:")
    assert has_element?(view, ".subworker", "analyst-helper")
    assert has_element?(view, "#member-count", "4 members")
    assert has_element?(view, "#tasks", "completed")

    {:ok, reloaded, _} = live(conn, "/examples/research-team")
    assert has_element?(reloaded, "#member-count", "4 members")
    assert has_element?(reloaded, "#messages", "Lua:")
    refute Playground.get("another-browser", "research-team")
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
    assert has_element?(view, "#definition-Aikido-Slices-Todo[open]")
  end

  test "a Lua request can be answered from LiveView and the same script continues", %{conn: conn} do
    {:ok, view, html} = live(conn, "/examples/hook-requests")
    assert html =~ "aikido.request"
    owner = start(view, "hook-requests", %{mode: "offline", lua: "true"})
    view |> form("#prompt-form", %{query: "Signals carry results"}) |> render_submit()
    await(owner, "hook-requests", &(&1.requests != []))
    [request] = Playground.get(owner, "hook-requests").requests
    assert has_element?(view, "#request-#{request.id}", "Allow the stamp tool to run?")
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

    reconnected |> form("#prompt-form", %{query: "Try denial"}) |> render_submit()
    await(owner, "hook-requests", &(&1.requests != []))
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

    assert has_element?(view, ".member-state", "count: 11")

    view |> element("button[phx-click=remove_squad]") |> render_click()
    await(owner, "nested-teams", &(length(&1.snapshot.members) == 2))
    assert_receive {:DOWN, ^squad_ref, :process, ^squad_pid, _}, 5_000
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5_000)

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
        child && map_size(child.children) == 3
      end)
    end

    spawn_squad.()

    retired =
      Enum.filter(playground_subscriptions(key), fn {_, sub} ->
        List.first(sub.member || []) == "again"
      end)

    assert length(retired) == 4

    assert :ok = Playground.command(owner, "nested-teams", :remove_member, %{member: "again"})
    await(owner, "nested-teams", fn run -> not Map.has_key?(run.snapshot.children, "again") end)
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

    assert has_element?(
             view,
             "[data-node=lead] [data-node=helper] [data-node=branch] [data-node=inner] [data-node=deeper]"
           )

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

  test "live mode shows an actionable configuration error without creating a run", %{conn: conn} do
    {:ok, view, _} = live(conn, "/examples/assistant")
    view |> form("#start-form", %{mode: "live"}) |> render_change()
    view |> form("#start-form", %{mode: "live", model: "unsupported:model"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#error", "Live mode needs")
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

  defp start(view, slug, options \\ %{}) do
    view |> form("#start-form", options) |> render_submit()
    render_async(view, 15_000)
    assert_receive {:run_updated, owner, ^slug}, 5_000
    on_exit(fn -> Playground.stop(owner, slug) end)
    owner
  end

  defp await(owner, slug, predicate, timeout \\ 5_000) do
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
