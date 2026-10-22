defmodule AgentExamplesWeb.LuaPermissionsLive do
  @moduledoc "Runtime Lua entrypoint selection and end-to-end caller scope."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "lua-permissions"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("permissions", %{"allow" => allow}, socket) when allow in ["true", "false"],
    do:
      ExamplePage.command(socket, :refresh_tools, %{
        tool_context: %{context: %{shared: %{allow_scope: allow == "true"}}}
      })

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section :if={active?(@run)} class="panel" id="lua-permissions">
        <h2>Application-owned Lua functions</h2>
        <p>Initially no functions are exposed. Allow session.whoami, then submit the script. Its result shows the browser actor and playground tenant. Send docs to compare the visible documentation after revoking access.</p>
        <button id="allow-scope" class="button secondary" phx-click="permissions" phx-value-allow="true">Allow scope function</button>
        <button id="deny-scope" class="button secondary" phx-click="permissions" phx-value-allow="false">Remove all functions</button>
      </section>
      <.conversation run={@run} prompt="return session.whoami()" />
    </.page>
    """
  end
end
