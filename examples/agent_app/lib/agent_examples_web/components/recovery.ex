defmodule AgentExamplesWeb.Components.Recovery do
  @moduledoc "Reusable recovery panel."
  use Phoenix.Component

  attr :run, :any, required: true

  def recovery(assigns) do
    ~H"""
    <section class="panel" id="recovery-instructions">
      <h2>Restore a conversation</h2>
      <p>
        Send a message, use Stop example, then Start example again. The ID stays the same; the PID changes. Ask again to check retained history.
      </p>
      <p :if={@run}>Current process: <code>{inspect(@run.record.pid)}</code></p>
    </section>
    """
  end
end
