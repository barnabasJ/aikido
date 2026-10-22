defmodule AgentExamplesWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agent_examples

  @session_options [
    store: :cookie,
    key: "_agent_examples",
    signing_salt: "example-session",
    same_site: "Lax",
    max_age: 31_536_000
  ]
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static, at: "/", from: :agent_examples, only: ~w(assets))
  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.mjs))

  plug(Plug.Static,
    at: "/vendor/live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(AgentExamplesWeb.Router)
end
