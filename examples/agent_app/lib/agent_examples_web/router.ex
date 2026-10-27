defmodule AgentExamplesWeb.Router do
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AgentExamplesWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:browser_identity)
  end

  scope "/", AgentExamplesWeb do
    pipe_through :browser

    live_dashboard("/dashboard",
      metrics: AgentExamples.Telemetry,
      home_app: {"Aikido", :agent_examples},
      additional_pages: [aikido: AgentExamplesWeb.TelemetryPage],
      request_logger: false,
      ecto_repos: []
    )

    live_session :examples, session: {__MODULE__, :live_session, []} do
      live("/", IndexLive)
      live("/examples/lua-permissions", LuaPermissionsLive)
      live("/examples/adaptive-tools", AdaptiveToolsLive)
      live("/examples/verified-work", VerifiedWorkLive)
      live("/examples/verified-team", VerifiedTeamLive)
      live("/examples/resilience", ResilienceLive)
      live("/examples/recovery", RecoveryLive)
      live("/examples/counter", CounterLive)
      live("/examples/cron", CronLive)
      live("/examples/checkpoint", CheckpointLive)
      live("/examples/checklist", ChecklistLive)
      live("/examples/notebook", NotebookLive)
      live("/examples/worker", WorkerLive)
      live("/examples/quicksort", QuicksortLive)
      live("/examples/team", TeamLive)
      live("/examples/nested-teams", NestedTeamsLive)
      live("/examples/assistant", AssistantLive)
      live("/examples/hooks", HooksLive)
      live("/examples/conversation", ConversationLive)
      live("/examples/hook-requests", HookRequestsLive)
      live("/examples/researcher", ResearcherLive)
      live("/examples/reviewer", ReviewerLive)
      live("/examples/research-team", ResearchTeamLive)
    end
  end

  defp browser_identity(conn, _) do
    put_session(conn, :browser_id, get_session(conn, :browser_id) || Ash.UUIDv7.generate())
  end

  def live_session(conn), do: %{"browser_id" => get_session(conn, :browser_id)}
end
