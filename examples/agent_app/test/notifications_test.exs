defmodule AgentExamples.NotificationsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.Playground
  @endpoint AgentExamplesWeb.Endpoint

  test "the notification page publishes a counter value and displays the subscribed child's acknowledgement" do
    assert Aikido.Agent.Info.agent_path!(AgentExamples.NotificationCounter) == :metrics
    owner = Ash.UUIDv7.generate()
    Playground.subscribe(owner)
    conn = build_conn() |> Plug.Test.init_test_session(%{browser_id: owner})
    {:ok, view, _} = live(conn, "/examples/notifications")
    on_exit(fn -> Playground.stop(owner, "notifications") end)

    assert has_element?(view, "#publish-increment[disabled]")
    view |> form("#start-form", %{}) |> render_submit()
    render_async(view, 15_000)
    await_run(owner, & &1.snapshot.own.enabled)

    assert has_element?(view, "#publish-increment:not([disabled])")
    view |> element("#publish-increment") |> render_click()
    await_run(owner, &(&1.snapshot.own.result == "Observer adopted 1"))

    assert has_element?(view, "#published-count", "1")
    assert has_element?(view, "#observed-count", "Observer adopted 1")

    view |> element("#publish-increment") |> render_click()
    await_run(owner, &(&1.snapshot.own.result == "Observer adopted 2"))
    assert has_element?(view, "#published-count", "2")
    assert has_element?(view, "#observed-count", "Observer adopted 2")

    assert %{snapshot: %{own: %{count: 2, enabled: true, result: "Observer adopted 2"}}} =
             Playground.get(owner, "notifications")

    assert has_element?(view, "#aikido-inspector")
  end

  defp await_run(owner, predicate) do
    wait_for_update(owner, predicate, System.monotonic_time(:millisecond) + 5_000)
  end

  defp wait_for_update(owner, predicate, deadline) do
    run = Playground.get(owner, "notifications")

    if run && run.snapshot && predicate.(run) do
      :ok
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:run_updated, ^owner, "notifications"} -> wait_for_update(owner, predicate, deadline)
      after
        remaining -> flunk("Notification example did not reach the expected state")
      end
    end
  end
end
