defmodule AgentExamplesWeb.ExamplePage do
  @moduledoc "Shared LiveView lifecycle for a browser-owned example run."
  import Phoenix.Component
  import Phoenix.LiveView
  alias AgentExamples.{Catalog, Playground}

  def on_mount(slug, _params, %{"browser_id" => owner}, socket) do
    example = Catalog.find(slug)
    if connected?(socket), do: Playground.subscribe()
    provider = Playground.provider_settings(owner)

    socket =
      socket
      |> assign(
        example: example,
        definitions: AgentExamples.Source.for_example(example),
        owner: owner,
        run: Playground.get(owner, slug),
        starting: false,
        error: nil,
        mode: provider.mode,
        provider: provider.provider,
        model: provider.model,
        key_configured: provider.key_configured?,
        provider_saved: false,
        lua: true,
        system_prompt: ai_default(example, :system_prompt, ""),
        max_iterations: ai_default(example, :max_iterations, 10)
      )
      |> attach_hook(:example_commands, :handle_event, &handle_event/3)
      |> attach_hook(:example_updates, :handle_info, &handle_info/2)
      |> attach_hook(:example_start, :handle_async, &handle_async/3)

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

  defp handle_event("settings", params, socket) do
    {:halt,
     assign(socket,
       mode: params["mode"] || "offline",
       model: params["model"] || socket.assigns.model,
       lua: params["lua"] == "true",
       system_prompt: Map.get(params, "system_prompt", socket.assigns.system_prompt),
       max_iterations: Map.get(params, "max_iterations", socket.assigns.max_iterations)
     )}
  end

  defp handle_event("start", params, socket) do
    owner = socket.assigns.owner
    slug = socket.assigns.example.slug

    params =
      Map.take(params, ["mode", "provider", "model", "lua", "system_prompt", "max_iterations"])

    {:halt,
     socket
     |> assign(starting: true, error: nil)
     |> start_async(:start_example, fn -> Playground.start(owner, slug, params) end)}
  end

  defp handle_event("stop", _, socket) do
    result = Playground.stop(socket.assigns.owner, socket.assigns.example.slug)
    {:halt, socket |> assign(error: command_error(result)) |> reload_run()}
  end

  defp handle_event(_, _, socket), do: {:cont, socket}

  defp handle_async(:start_example, {:ok, {:ok, run}}, socket),
    do: {:halt, assign(socket, run: run, starting: false, error: nil)}

  defp handle_async(:start_example, {:ok, {:error, reason}}, socket),
    do: {:halt, assign(socket, starting: false, error: reason)}

  defp handle_async(:start_example, {:exit, reason}, socket),
    do: {:halt, assign(socket, starting: false, error: "Could not start: #{inspect(reason)}")}

  defp handle_async(_, _, socket), do: {:cont, socket}

  defp handle_info({:provider_updated, owner}, socket) do
    socket =
      if owner == socket.assigns.owner,
        do: assign_provider(socket, Playground.provider_settings(owner)),
        else: socket

    {:halt, socket}
  end

  defp handle_info({:run_updated, owner, slug}, socket) do
    socket =
      if owner == socket.assigns.owner && slug == socket.assigns.example.slug,
        do: reload_run(socket),
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

  def command(socket, action, input) do
    result = Playground.command(socket.assigns.owner, socket.assigns.example.slug, action, input)
    {:noreply, socket |> assign(error: command_error(result)) |> reload_run()}
  end

  defp reload_run(socket),
    do: assign(socket, :run, Playground.get(socket.assigns.owner, socket.assigns.example.slug))

  defp ai_default(example, key, fallback) do
    case Ash.Resource.Info.attribute(example.resource, key) do
      nil -> fallback
      attribute -> attribute.default || fallback
    end
  end

  defp command_error(:ok), do: nil
  defp command_error({:error, reason}), do: reason
end
