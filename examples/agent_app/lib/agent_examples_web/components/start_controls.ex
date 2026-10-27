defmodule AgentExamplesWeb.Components.StartControls do
  @moduledoc "Reusable start controls display for example pages."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]
  alias AgentExamples.Catalog
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]
  attr :example, :map, required: true
  attr :run, :any, required: true
  attr :starting, :boolean, required: true
  attr :mode, :string, required: true
  attr :provider, :string, required: true
  attr :model, :string, required: true
  attr :max_iterations, :any, required: true
  attr :system_prompt, :string, required: true
  attr :lua, :boolean, required: true

  def start_controls(assigns) do
    ~H"""
    <section :if={!active?(@run)} class="panel" id="start-panel">
      <.section_heading>
        <:title>Make it live</:title>
        <span>Your own instance</span>
      </.section_heading>
      <form id="start-form" phx-submit="start" phx-change="settings">
        <div :if={Catalog.ai?(@example)} class="settings-grid">
          <input type="hidden" name="mode" value={@mode} />
          <input type="hidden" name="provider" value={@provider} />
          <input type="hidden" name="model" value={@model} />
          <label>Maximum model turns<input
            type="number"
            name="max_iterations"
            min="1"
            value={@max_iterations}
            required
          /></label>
          <label class="settings-note">System prompt<textarea name="system_prompt" rows="5">{@system_prompt}</textarea></label>
          <label :if={Catalog.lua_optional?(@example)} class="checkbox-label"><input
            type="checkbox"
            name="lua"
            value="true"
            checked={@lua}
          /> Enable Lua scripting tools</label>
          <input :if={Catalog.requires_lua?(@example)} type="hidden" name="lua" value="true" />
          <p :if={Catalog.requires_lua?(@example)} id="lua-required" class="muted settings-note">
            Lua scripting tools are required for this example.
          </p>
          <p class="muted settings-note">
            Offline mode runs real tools without a key. Live mode uses the shared provider settings above.
          </p>
        </div>
        <button class="button primary" disabled={@starting}>{if @starting,
          do: "Starting…",
          else: "Start example"} <span>→</span></button>
      </form>
    </section>
    """
  end
end
