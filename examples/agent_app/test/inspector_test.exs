defmodule AgentExamples.InspectorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Aikido.Inspector.History, as: Inspector

  test "negative filter terms hide lifecycle entries without hiding business routing errors" do
    snapshot = %{id: "root", inspected_state: %{}}
    lifecycle = %{signal: %{type: "aikido.agent.lifecycle.ready"}, directives: [], error: nil}

    command = %{
      signal: %{type: "unknown.command"},
      directives: [],
      error: "Missing command route"
    }

    history = Inspector.record(Inspector.new(), snapshot, [], lifecycle, %{})
    history = Inspector.record(%{history | sequence: 100_000}, snapshot, [], command, %{})

    render = fn filter ->
      render_component(&Aikido.Inspector.Components.inspector/1,
        history: history,
        filter: filter
      )
    end

    hidden = render.("-lifecycle")
    refute hidden =~ "phx-value-sequence=\"1\""
    assert hidden =~ "100001"
    assert hidden =~ "Missing command route"
    assert hidden =~ "unknown.command"
    visible = render.("")
    assert visible =~ "phx-value-sequence=\"1\""
    assert visible =~ "aikido.agent.lifecycle.ready"
    refute visible =~ "inspector-lifecycle"
    assert render.("unknown -lifecycle") =~ "Missing command route"
    refute render.("unknown -command") =~ "phx-value-sequence=\"100001\""
  end

  test "filter combines case-insensitive inclusions and exclusions with agent identities" do
    event = %{
      agent_id: "root/squad/worker",
      agent_pid: "<0.123.0>",
      execution: %{signal: %{type: "quicksort.sorted"}}
    }

    filter = &Inspector.Filter.parse/1
    assert Inspector.Filter.matches?(event, filter.("SQUAD quicksort -lifecycle"))
    assert Inspector.Filter.matches?(event, filter.("<0.123.0> -failed"))
    refute Inspector.Filter.matches?(event, filter.("squad -sorted"))
    refute Inspector.Filter.matches?(event, filter.("other quicksort"))
    assert Inspector.Filter.matches?(event, filter.("  -  "))
  end

  test "projections redact secrets, private scope and executable values" do
    projected =
      Inspector.project_state(%{
        state: %{count: 1},
        ai: %{
          context: %{messages: ["private history"]},
          prepared_tools: [fn -> :secret end],
          llm_opts: [api_key: "never-show", temperature: 0.2],
          config: %{"apiKey" => "hidden"}
        },
        bytes: <<255>>,
        tuple: {"authorization", "hidden"},
        process: self()
      })

    encoded = Jason.encode!(projected)
    refute encoded =~ "never-show"
    refute encoded =~ "hidden"
    refute encoded =~ "private history"
    assert projected["state"]["count"] == 1
    assert projected["ai"]["config"]["apiKey"] == "[redacted]"
    assert projected["process"] == "[process]"
  end

  test "timeline retains only bounded history with precise nested changes" do
    before = %{"state" => %{"count" => 1}}
    snapshot = %{id: "root/worker", inspected_state: %{"state" => %{"count" => 2}}}
    execution = %{signal: %{type: "counter.add"}, directives: [], error: nil}

    history =
      Enum.reduce(1..150, Inspector.new(), fn _, history ->
        Inspector.record(history, snapshot, ["worker"], execution, before)
      end)

    assert length(history.entries) == 100
    assert hd(history.entries).sequence == 150
    assert hd(history.entries).changes == [%{path: "state.count", before: 1, after: 2}]
    assert hd(history.entries).agent_id == "root/worker"
    assert Map.keys(history) |> Enum.sort() == [:entries, :sequence]
  end

  test "process labels retain their ID tooltip and stable readable hex color" do
    snapshot = %{id: "root/squad/worker", inspected_state: %{}}
    execution = %{signal: %{type: "ai.react.tool.completed"}, directives: [], error: nil}

    history =
      Inspector.record(Inspector.new(), snapshot, ["squad", "worker"], execution, %{}, self())

    history = Inspector.record(history, snapshot, ["squad", "worker"], execution, %{}, self())

    html =
      render_component(&Aikido.Inspector.Components.inspector/1,
        history: history
      )

    pid_label = self() |> :erlang.pid_to_list() |> to_string()
    assert html =~ pid_label |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    assert html =~ ~s(title="root/squad/worker")
    [first, second] = Regex.scan(~r/style="color: (#[0-9A-F]{6})"/, html, capture: :all_but_first)
    assert first == second
  end

  test "a pinned snapshot remains inspectable after it leaves bounded history and raw HTML is escaped" do
    event = %{signal: %{type: "pinned.event"}, directives: [], error: nil}
    snapshot = %{id: "root/worker", inspected_state: %{"text" => "<script>alert(1)</script>"}}
    history = Inspector.record(Inspector.new(), snapshot, ["worker"], event, %{})
    pinned = hd(history.entries)
    newer = %{event | signal: %{type: "new.event"}}

    history =
      Enum.reduce(1..110, history, fn _, history ->
        Inspector.record(
          history,
          %{snapshot | inspected_state: %{"count" => 2}},
          ["worker"],
          newer,
          %{}
        )
      end)

    refute Enum.any?(history.entries, &(&1.sequence == pinned.sequence))

    html =
      render_component(&Aikido.Inspector.Components.inspector/1,
        history: history,
        selected: pinned,
        view: "after",
        format: "raw"
      )

    assert html =~ "inspector-value-1-after-raw"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end

  test "signal payloads and returned directives retain useful details without executable closures" do
    event = %{
      signal: %Aikido.Signal{type: "work.start", data: %{api_key: "hidden", count: 2}},
      directives: [
        %Aikido.Directives.AsyncTask{
          work: fn -> send(self(), :executed) end,
          success_type: "work.done",
          error_type: "work.failed",
          payload: %{count: 7, api_key: "hidden"},
          source: "/example",
          target: self()
        }
      ],
      error: nil
    }

    projected = Inspector.project_event(event)
    assert projected.signal.type == "work.start"
    assert projected.signal.data["api_key"] == "[redacted]"
    assert [%{type: "Aikido.Directives.AsyncTask", fields: fields}] = projected.directives
    assert fields["work"] == "[function]"
    assert fields["success_type"] == "work.done"
    assert fields["error_type"] == "work.failed"
    assert fields["payload"] == %{"count" => 7, "api_key" => "[redacted]"}
    assert fields["source"] == "/example"
    assert fields["target"] == "[process]"
    refute_received :executed
    refute Jason.encode!(projected) =~ "hidden"
  end

  test "a rejected assignment retains its input and unchanged before/after state with a readable explanation" do
    error =
      Aikido.Team.Errors.DelegationCycle.exception(members: ["engineer", "auditor", "engineer"])

    execution =
      Inspector.project_event(%{
        signal: %Aikido.Signal{
          type: "aikido.ash.team.assign_task",
          data: %{member: "auditor", requester: "engineer"}
        },
        directives: [],
        error: Ash.Error.to_error_class(error)
      })

    state = %{"team" => %{"tasks" => %{}}}

    history =
      Inspector.record(
        Inspector.new(),
        %{id: "root/squad", inspected_state: state},
        ["squad"],
        execution,
        state,
        self()
      )

    entry = hd(history.entries)

    assert entry.before == state
    assert entry.after == state
    assert entry.changes == []
    assert execution.signal.data["member"] == "auditor"
    assert execution.error_message =~ "engineer -> auditor -> engineer"

    html =
      render_component(&Aikido.Inspector.Components.inspector/1,
        history: history
      )

    assert html =~ "State unchanged."
    assert html =~ "Signal rejected"
    assert html =~ "0 directives returned."
    assert html =~ "The agent reported its state after this error."
    assert html =~ "Input signal"
    assert html =~ "Before state"
    assert html =~ "After state"
    assert html =~ "Raw error details"
    refute html =~ "Processing error: {"
  end

  test "already recorded cycle errors also get their canonical explanation" do
    error = %{"class" => "invalid", "errors" => [%{"members" => ["a", "b", "a"]}]}
    assert Inspector.error_message(error) =~ "circular wait: a -> b -> a"
    assert Inspector.error_message(error) =~ "background mode"
  end
end
