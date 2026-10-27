defmodule AgentExamplesWeb.Components.LuaPermissions do
  @moduledoc "Reusable lua permissions panel and command mount hook."
  use Phoenix.Component
  import Phoenix.LiveView
  alias AgentExamplesWeb.ExamplePage
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :lua_permissions_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("permissions", %{"allow" => allow}, socket) when allow in ["true", "false"],
    do:
      ExamplePage.command(socket, :refresh_tools, %{
        tool_context: %{context: %{shared: %{allow_scope: allow == "true"}}}
      })

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def lua_permissions(assigns) do
    ~H"""
    <section :if={active?(@run)} class="panel" id="lua-permissions">
      <h2>Application-owned Lua functions</h2>
      <p>
        Initially no functions are exposed. Allow session.whoami, then submit the script. Its result shows the browser actor and playground tenant. Send docs to compare the visible documentation after revoking access.
      </p>
      <button
        id="allow-scope"
        class="button secondary"
        phx-click="permissions"
        phx-value-allow="true"
      >Allow scope function</button>
      <button
        id="deny-scope"
        class="button secondary"
        phx-click="permissions"
        phx-value-allow="false"
      >Remove all functions</button>
    </section>
    """
  end
end
