defmodule AgentExamplesWeb.DelegatedWorkTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "delegated work includes nested and retained teams with unambiguous paths" do
    task = %{id: "1", member: "analyst", status: :completed, result: "Root result"}
    nested = %{tasks: [%{task | id: "3", status: :dispatched}], children: %{}}
    retired = %{tasks: [%{task | id: "2", result: "Retained result"}], children: %{}}

    run = %{
      snapshot: %{tasks: [task], children: %{"investigation" => nested, "retired" => retired}}
    }

    html = render_component(&AgentExamplesWeb.ExampleComponents.delegated_work/1, run: run)
    assert html =~ "3 tasks across the tree"
    assert html =~ "investigation / analyst"
    assert html =~ "retired / analyst"
    assert html =~ "Dispatched by Root team"
    assert html =~ "Retained result"
    assert html =~ ~s(data-owner="investigation")
    assert html =~ ~s(data-owner="retired")
  end

  test "foreground tasks expose a background control at the owning team path" do
    task = %{
      id: "waiting-task",
      member: "worker",
      requester: :analyst,
      mode: :foreground,
      status: :dispatched,
      result: nil
    }

    run = %{snapshot: %{tasks: [], children: %{"squad" => %{tasks: [task], children: %{}}}}}
    html = render_component(&AgentExamplesWeb.ExampleComponents.delegated_work/1, run: run)
    assert html =~ "Continue in background"
    assert html =~ ~s(phx-value-task-id="waiting-task")
    assert html =~ ~s(phx-value-team-path="[&quot;squad&quot;]")
    assert html =~ "Requested by analyst"

    background = put_in(run.snapshot.children["squad"].tasks, [%{task | mode: :background}])

    refute render_component(&AgentExamplesWeb.ExampleComponents.delegated_work/1, run: background) =~
             "Continue in background"
  end
end
