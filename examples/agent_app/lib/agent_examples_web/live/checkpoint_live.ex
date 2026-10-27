defmodule AgentExamplesWeb.CheckpointLive do
  @moduledoc "Checkpoint a counter, kill its process, and restore the same durable identity."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamples.Playground
  on_mount({AgentExamplesWeb.ExamplePage, "checkpoint"})
  def mount(_, _, socket), do: {:ok, assign(socket, crash_monitor: nil)}

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel" id="checkpoint-counter">
        <h2>Live state and saved state</h2>
        <p><strong id="checkpoint-count">{own(@run)[:count] || 0}</strong> live count</p>
        <p>
          Add a value, checkpoint it, add another value, then crash. Start the example again: the ID stays the same, the PID changes, and only the checkpointed count returns.
        </p>
        <p>
          This demo uses a one-hour periodic sync interval and disables automatic crash restart. Checkpoint now performs a graceful stop and reactivation through domain commands. Restore is manual so you can inspect the stopped process first.
        </p>
        <p :if={@run}>Process: <code id="checkpoint-pid">{inspect(@run.record.pid)}</code></p>
        <button
          id="checkpoint-add"
          class="button secondary"
          phx-click="increment"
          disabled={!active?(@run) || @starting}
        >Add 1</button>
        <button
          id="checkpoint-save"
          class="button primary"
          phx-click="checkpoint"
          disabled={!active?(@run) || @starting}
        >Checkpoint now</button>
        <button
          id="checkpoint-crash"
          class="button danger"
          phx-click="crash"
          disabled={!active?(@run) || @starting || !is_nil(@crash_monitor)}
        >Crash agent</button>
        <p :if={@run && @run.status == :stopped} id="checkpoint-stopped">
          Process stopped. Use Start example above to restore its saved identity.
        </p>
      </section>
    </.page>
    """
  end

  def handle_event("increment", _, socket) do
    {:halt, socket} = AgentExamplesWeb.ExamplePage.command(socket, :add, %{amount: 1})
    {:noreply, socket}
  end

  def handle_event("checkpoint", _, socket) do
    owner = socket.assigns.owner

    {:noreply,
     socket
     |> assign(starting: true)
     |> start_async(:start_example, fn ->
       with :ok <- Playground.stop(owner, "checkpoint"),
            do: Playground.start(owner, "checkpoint", %{})
     end)}
  end

  def handle_event("crash", _, socket) do
    monitor = Process.monitor(socket.assigns.run.record.pid)
    signal = AgentExamples.CheckpointCounter.Signals.Crash.new!(%{})
    Aikido.AgentServer.cast(socket.assigns.run.record.pid, signal)
    {:noreply, assign(socket, crash_monitor: monitor)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{crash_monitor: ref}} = socket) do
    :ok = Playground.stop(socket.assigns.owner, "checkpoint")

    {:noreply,
     assign(socket, crash_monitor: nil, run: Playground.get(socket.assigns.owner, "checkpoint"))}
  end
end
