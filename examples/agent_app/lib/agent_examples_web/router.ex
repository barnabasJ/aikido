defmodule AgentExamplesWeb.Router do
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router

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

    live_session :examples, session: {__MODULE__, :live_session, []} do
      live("/", IndexLive)
      live("/examples/:slug", ExampleLive)
    end
  end

  defp browser_identity(conn, _) do
    if get_session(conn, :browser_id),
      do: conn,
      else: put_session(conn, :browser_id, Aikido.Util.generate_id())
  end

  def live_session(conn), do: %{"browser_id" => get_session(conn, :browser_id)}
end
