defmodule AgentExamplesWeb.Components.ProviderSettings do
  @moduledoc "Reusable provider settings display for example pages."
  use Phoenix.Component
  alias AgentExamples.Catalog
  import Phoenix.LiveView
  alias AgentExamples.Playground

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> attach_hook(:provider_settings_commands, :handle_event, &handle_event/3)
      |> attach_hook(:provider_updates, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_event("provider_settings", params, socket) do
    {:halt,
     assign(socket,
       mode: params["mode"] || "offline",
       provider: params["provider"] || socket.assigns.provider,
       model: params["model"] || socket.assigns.model,
       provider_saved: false
     )}
  end

  defp handle_event("save_provider", params, socket) do
    case Playground.configure_provider(socket.assigns.owner, params) do
      {:ok, settings} ->
        {:halt, assign_provider(socket, settings) |> assign(error: nil, provider_saved: true)}

      {:error, error} ->
        {:halt, assign(socket, error: error, provider_saved: false)}
    end
  end

  defp handle_event(_, _, socket), do: {:cont, socket}

  defp handle_info({:provider_updated, owner}, socket) do
    socket =
      if owner == socket.assigns.owner,
        do: assign_provider(socket, Playground.provider_settings(owner)),
        else: socket

    {:halt, socket}
  end

  defp handle_info(_, socket), do: {:cont, socket}

  defp assign_provider(socket, settings),
    do:
      assign(socket,
        mode: settings.mode,
        provider: settings.provider,
        model: settings.model,
        key_configured: settings.key_configured?
      )

  attr :example, :map, required: true
  attr :mode, :string, required: true
  attr :provider, :string, required: true
  attr :model, :string, required: true
  attr :key_configured, :boolean, required: true
  attr :provider_saved, :boolean, required: true

  def provider_settings(assigns) do
    ~H"""
    <section :if={Catalog.ai?(@example)} class="panel" id="shared-ai-settings">
      <h2>AI provider · shared by all AI examples</h2>
      <form
        id="provider-form"
        phx-submit="save_provider"
        phx-change="provider_settings"
        class="settings-grid"
      >
        <label>Model mode<select name="mode"><option value="offline" selected={@mode == "offline"}>
          Offline · scripted model
        </option><option value="live" selected={@mode == "live"}>Live · your provider</option></select></label>
        <label :if={@mode == "live"}>Provider<select name="provider"><option
          :for={{label, value} <- AgentExamples.AI.Providers.choices()}
          value={value}
          selected={@provider == value}
        >
          {label}
        </option></select></label>
        <label :if={@mode == "live"}>Model ID<input
          name="model"
          value={@model}
          placeholder="glm-5.3"
          required
        /></label>
        <label :if={@mode == "live"}>API key<input
          type="password"
          name="api_key"
          value=""
          autocomplete="off"
          placeholder={
            if @key_configured,
              do: "Key saved · leave blank to keep it",
              else: "Your provider API key"
          }
        /></label>
        <p class="muted settings-note">
          Saved locally across restarts for this browser. All AI examples and workers use these settings when started. Restart an active example to change its provider. API keys are encrypted with AshCloak in SQLite and never included in agent checkpoints.
        </p>
        <button id="save-provider" class="button secondary">Save AI settings</button>
        <p :if={@provider_saved} role="status" id="provider-saved">
          AI settings saved for all AI examples.
        </p>
      </form>
    </section>
    """
  end
end
