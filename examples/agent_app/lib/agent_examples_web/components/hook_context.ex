defmodule AgentExamplesWeb.Components.HookContext do
  @moduledoc "Shared lifecycle-hook context and error display."
  use Phoenix.Component
  attr :run, :any, required: true

  def hook_context(assigns) do
    ~H"""
    <section class="panel" id="hook-inspector">
      <h2>Hook context</h2>
      <p class="muted">
        Synchronous hooks finish before the next step. Async context enters the next eligible model request.
      </p>
      <ol id="hook-context">
        <li :for={text <- if(@run, do: Map.get(@run.snapshot.ai, :hook_messages, []), else: [])}>
          {text}
        </li>
      </ol>
      <p
        :for={error <- if(@run, do: Map.get(@run.snapshot.ai, :hook_errors, []), else: [])}
        class="error"
      >
        {inspect(error)}
      </p>
    </section>
    """
  end
end
