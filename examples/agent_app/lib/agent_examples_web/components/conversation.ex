defmodule AgentExamplesWeb.Components.Conversation do
  @moduledoc "Conversation output, prompt controls and shared command handling through on_mount."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1, message: 1]
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1, busy?: 1]
  import AgentExamplesWeb.Markdown
  alias AgentExamplesWeb.ExamplePage

  def on_mount(mode, _params, _session, socket) when mode in [:ask, :queue] do
    {:cont,
     socket
     |> assign(:conversation_mode, mode)
     |> attach_hook(:conversation_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("ask", %{"query" => query}, socket) do
    if socket.assigns.conversation_mode == :queue && busy?(socket.assigns.run),
      do: ExamplePage.command(socket, :message, %{text: query}),
      else: ExamplePage.command(socket, :ask, %{query: query})
  end

  defp handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})
  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true
  attr :prompt, :string, default: "Signals carry results"
  attr :queue_messages, :boolean, default: false
  slot :inner_block

  def conversation(assigns) do
    ~H"""
    <section class="panel conversation">
      {render_slot(@inner_block)}
      <.section_heading>
        <:title>Conversation</:title>
        <span>{if @run,
          do: "#{@run.mode} model",
          else: "Ready when you are"}</span>
      </.section_heading>
      <div :if={!@run || @run.messages == []} class="empty-state">
        <span class="empty-symbol">✳</span><h3>A prompt starts the story.</h3><p>
          Start the example, then send a task. Tool calls and worker results will appear as they happen.
        </p>
      </div>
      <div id="messages" aria-live="polite">
        <.message
          :for={{message, index} <- Enum.with_index(if(@run, do: @run.messages, else: []))}
          id={"message-#{index}"}
          class={["message", to_string(message.role)]}
          label={if message.role == :user, do: "YOU", else: "AGENT"}
          text={message.text}
        />
      </div>
      <div :if={busy?(@run)} class="working" role="status">
        <span class="live-dot"></span> Working through model turns and tools…
      </div>
      <section
        :if={active?(@run) && busy?(@run) && Map.get(@run.snapshot.ai, :streaming_text, "") != ""}
        id="stream-output"
        aria-live="polite"
      >
        <h3>
          {if @run.snapshot.ai.status == :waiting,
            do: "Answer waiting for todos",
            else: "Streaming answer"}
        </h3>
        <.markdown text={Map.get(@run.snapshot.ai, :streaming_text, "")} />
        <details>
          <summary>Thinking</summary><.markdown text={
            Map.get(@run.snapshot.ai, :streaming_thinking, "")
          } />
        </details>
      </section>
      <form id="prompt-form" phx-submit="ask" class="prompt-form">
        <label for="query">Your task</label><textarea
          id="query"
          name="query"
          rows="3"
          disabled={!active?(@run) || (busy?(@run) && !@queue_messages)}
        >{@prompt}</textarea>
        <button
          class="button primary"
          disabled={!active?(@run) || (busy?(@run) && !@queue_messages)}
        >{if busy?(@run) && @queue_messages,
          do: "Queue message",
          else: "Send task →"}</button>
      </form>
    </section>
    """
  end
end
