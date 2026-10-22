defmodule AgentExamplesWeb.ExampleComponents do
  @moduledoc "Shared framing, conversation and topology visuals for the example pages."
  use Phoenix.Component
  import AgentExamplesWeb.Components
  alias AgentExamples.Catalog

  attr :example, :map, required: true
  attr :definitions, :list, required: true
  attr :run, :any, required: true
  attr :starting, :boolean, required: true
  attr :error, :any, required: true
  attr :mode, :string, required: true
  attr :provider, :string, required: true
  attr :key_configured, :boolean, required: true
  attr :provider_saved, :boolean, required: true
  attr :model, :string, required: true
  attr :lua, :boolean, required: true
  attr :system_prompt, :string, required: true
  attr :max_iterations, :any, required: true
  slot :inner_block, required: true
  slot :inspector

  def page(assigns) do
    ~H"""
    <.shell active={@example.slug}>
      <header class="example-header">
        <.link navigate="/" class="back-link">← All examples</.link>
        <div class="eyebrow">{@example.eyebrow}</div>
        <div class="title-row">
          <h1>{@example.title}</h1><span class={["status-pill", active?(@run) && "on"]}>{if @starting,
            do: "Starting…",
            else: if(@run, do: to_string(@run.status), else: "Not started")}</span>
        </div>
        <p>{@example.description}</p>
      </header>
      <section class="panel overview">
        <p>{@example.detail}</p><.flow steps={@example.flow} />
      </section>
      <div :if={@error || (@run && @run.error)} role="alert" id="error" class="error-banner">
        {@error || @run.error}
      </div>
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
      <div class="workspace">
        <div class="primary-column">
          <section :if={!active?(@run)} class="panel" id="start-panel">
            <div class="section-heading">
              <h2>Make it live</h2><span>Your own instance</span>
            </div>
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
                <label class="checkbox-label"><input
                  type="checkbox"
                  name="lua"
                  value="true"
                  checked={@lua}
                /> Include Ash AI + Lua tools</label>
                <p class="muted settings-note">
                  Offline mode runs real tools without a key. Live mode uses the shared provider settings above.
                </p>
              </div>
              <button class="button primary" disabled={@starting}>{if @starting,
                do: "Starting…",
                else: "Start example"} <span>→</span></button>
            </form>
          </section>
          {render_slot(@inner_block)}
        </div>
        <aside class="inspector">
          {render_slot(@inspector)}
          <section class="panel">
            <div class="section-heading">
              <h2>Under the hood</h2><span class="live-dot"></span>
            </div><dl>
              <dt>Runtime</dt><dd>Aikido.Default</dd><dt>State</dt><dd>Ash resource attributes</dd><dt>
                Instance
              </dt><dd class="instance-id">{if @run, do: @run.record.id, else: "Not started"}</dd><dt :if={
                Catalog.ai?(@example)
              }>
                Model turns
              </dt><dd :if={Catalog.ai?(@example)}>
                {if @run, do: Map.get(@run.snapshot.ai, :iteration, 0), else: 0}
              </dd>
              <dt :if={Catalog.ai?(@example) && @run}>Model in this agent</dt>
              <dd :if={Catalog.ai?(@example) && @run} id="active-model">
                {Map.get(@run.snapshot.ai, :model_label, "Not configured")}
              </dd>
            </dl><button :if={active?(@run)} id="stop-example" phx-click="stop" class="button danger">Stop example</button>
          </section>
          <section class="panel">
            <div class="section-heading">
              <h2>Signal activity</h2><span>Latest first · UTC</span>
            </div><p :if={!@run || @run.events == []} class="muted">
              Signals will appear here as you interact.
            </p><ol id="events" class="events">
              <li :for={event <- if(@run, do: Enum.take(@run.events, 20), else: [])}>
                <span>{event.time}</span><code>{event.type}</code>
              </li>
            </ol>
          </section>
        </aside>
      </div>
      <section class="definitions" id="definitions" aria-label="Example source definitions">
        <div class="section-heading">
          <h2>Code definitions</h2><span>Agents and slices open by default · each module opens independently</span>
        </div>
        <details
          :for={definition <- @definitions}
          id={definition.id}
          open={definition.open?}
          phx-update="ignore"
          class="code-definition"
          data-kind={definition.category}
        >
          <summary>
            <span class="definition-name">{definition.name}</span><span class="definition-path">{definition.path}</span>
          </summary>
          <pre><code>{definition.code}</code></pre>
        </details>
      </section>
      <footer class="page-footer">
        Instances stay available while the server runs. Stop an example to release its processes.
      </footer>
    </.shell>
    """
  end

  attr :run, :any, required: true
  attr :prompt, :string, default: "Signals carry results"
  attr :queue_messages, :boolean, default: false
  slot :inner_block

  def conversation(assigns) do
    ~H"""
    <section class="panel conversation">
      {render_slot(@inner_block)}
      <div class="section-heading">
        <h2>Conversation</h2><span>{if @run,
          do: "#{@run.mode} model",
          else: "Ready when you are"}</span>
      </div>
      <div :if={!@run || @run.messages == []} class="empty-state">
        <span class="empty-symbol">✳</span><h3>A prompt starts the story.</h3><p>
          Start the example, then send a task. Tool calls and worker results will appear as they happen.
        </p>
      </div>
      <div id="messages" aria-live="polite">
        <article
          :for={{message, index} <- Enum.with_index(if(@run, do: @run.messages, else: []))}
          id={"message-#{index}"}
          class={["message", to_string(message.role)]}
        >
          <span>{if message.role == :user, do: "YOU", else: "AGENT"}</span><pre>{message.text}</pre>
        </article>
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
        <pre>{Map.get(@run.snapshot.ai, :streaming_text, "")}</pre>
        <details>
          <summary>Thinking</summary><pre>{Map.get(@run.snapshot.ai, :streaming_thinking, "")}</pre>
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

  attr :run, :any, required: true
  attr :orchestrator, :boolean, default: false
  attr :compact, :boolean, default: false
  slot :inner_block

  def team_topology(assigns) do
    ~H"""
    <section class={["panel", @compact && "nested-team-panel"]}>
      <div class="section-heading">
        <h2>Live topology</h2><span id="member-count">{length(members(@run))} members</span>
      </div>
      <.topology
        members={members(@run)}
        children={if @run, do: @run.snapshot.children, else: %{}}
        orchestrator={@orchestrator}
        compact={@compact}
      />
      {render_slot(@inner_block)}
      <div :if={@run && @run.snapshot.tasks != []} class="task-list" id="tasks">
        <h3>Delegated work</h3><div :for={task <- @run.snapshot.tasks}>
          <strong>{task.member}</strong><span class="status-pill">{task.status}</span><p>
            {result_text(task.result)}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :run, :any, required: true

  def team_activity(assigns) do
    assigns =
      assign(
        assigns,
        :agents,
        if(assigns.run, do: agent_activities(assigns.run.snapshot), else: [])
      )

    ~H"""
    <section :if={@run} class="panel team-activity" id="team-activity">
      <div class="section-heading">
        <h2>What the team is doing</h2>
        <span>{Enum.count(
          @agents,
          &(active?(@run) && &1.activity.status in [:setup, :running, :waiting])
        )} active · {length(@agents)} agents</span>
      </div>
      <div class="agent-activity-grid">
        <article
          :for={agent <- @agents}
          class="agent-activity"
          data-agent={agent.path}
          data-status={if active?(@run), do: agent.activity.status, else: :stopped}
        >
          <div class="agent-activity-heading">
            <strong>{agent.path}</strong><span class="status-pill">{if active?(@run),
              do: agent.activity.stage,
              else: "Stopped"}</span>
          </div>
          <p class="muted">Model turns: {agent.activity.iteration}</p>
          <p :if={agent.activity.task} class="agent-task">{agent.activity.task}</p>
          <div :if={agent.activity.tools != []} class="agent-tools">
            <p class="muted">Tools used for this task</p>
            <details :for={tool <- agent.activity.tools} data-tool-status={tool.status}>
              <summary>
                {tool.label}<span>{case tool.status do
                  :pending -> "Pending result"
                  :completed -> "Succeeded"
                  :failed -> "Failed"
                end}</span>
              </summary>
              <small>Tool: {tool.name}</small>
              <pre>{tool.input}</pre>
              <details :if={tool.result}>
                <summary>Tool result</summary><pre>{tool.result}</pre>
              </details>
            </details>
          </div>
          <details
            :if={agent.activity.output not in [nil, ""]}
            open={agent.activity.status == :running}
          >
            <summary>
              {if agent.activity.status == :completed, do: "Answer", else: "Latest output"}
            </summary>
            <pre>{agent.activity.output}</pre>
          </details>
          <p :if={agent.activity.error} class="error-banner">{result_text(agent.activity.error)}</p>
        </article>
      </div>
    </section>
    """
  end

  defp agent_activities(snapshot, path \\ ["Orchestrator"]) do
    own =
      if snapshot.activity,
        do: [%{path: Enum.join(path, " / "), activity: snapshot.activity}],
        else: []

    own ++
      Enum.flat_map(Enum.sort_by(snapshot.children, &elem(&1, 0)), fn {name, child} ->
        agent_activities(child, path ++ [name])
      end)
  end

  def active?(nil), do: false
  def active?(run), do: run.status != :stopped
  def busy?(run), do: run && run.status == :running
  def own(nil), do: %{}
  def own(run), do: run.snapshot.own
  def members(nil), do: []
  def members(run), do: run.snapshot.members
  defp result_text(value) when is_binary(value), do: value
  defp result_text(nil), do: ""
  defp result_text(value), do: inspect(value)
end
