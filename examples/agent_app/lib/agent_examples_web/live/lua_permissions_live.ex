defmodule AgentExamplesWeb.LuaPermissionsLive do
  @moduledoc "Runtime Lua entrypoint selection and end-to-end caller scope."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.LuaPermissions, only: [lua_permissions: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "lua-permissions"})
  on_mount({AgentExamplesWeb.Components.LuaPermissions, :default})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.lua_permissions run={@run} />
      <.conversation run={@run} prompt="return session.whoami()" />
    </.page>
    """
  end
end
