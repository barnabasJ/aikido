defmodule AgentExamplesWeb.ExampleLive do
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.Components
  alias AgentExamples.{Catalog, Playground}

  def mount(%{"slug" => slug}, %{"browser_id" => owner}, socket) do
    case Catalog.find(slug) do
      nil ->
        {:ok, push_navigate(socket, to: "/")}

      example ->
        if connected?(socket), do: Playground.subscribe()

        {:ok,
         assign(socket,
           example: example,
           definitions: AgentExamples.Source.for_example(example),
           owner: owner,
           run: Playground.get(owner, slug),
           starting: false,
           error: nil,
           mode: "offline",
           model: System.get_env("AIKIDO_AI_MODEL", "zai:glm-5.3"),
           lua: true,
           system_prompt: ai_default(example, :system_prompt, ""),
           max_iterations: ai_default(example, :max_iterations, 10),
           tree_parent: "[]",
           tree_kind: "agent",
           tree_name: "",
           prompt: prompt(example)
         )}
    end
  end

  def handle_event("settings", params, socket),
    do:
      {:noreply,
       assign(socket,
         mode: params["mode"] || "offline",
         model: params["model"] || socket.assigns.model,
         lua: params["lua"] == "true",
         system_prompt: Map.get(params, "system_prompt", socket.assigns.system_prompt),
         max_iterations: Map.get(params, "max_iterations", socket.assigns.max_iterations)
       )}

  def handle_event("start", params, socket) do
    owner = socket.assigns.owner
    slug = socket.assigns.example.slug

    {:noreply,
     socket
     |> assign(starting: true, error: nil)
     |> start_async(:start_example, fn -> Playground.start(owner, slug, params) end)}
  end

  def handle_event("stop", _, socket) do
    result = Playground.stop(socket.assigns.owner, socket.assigns.example.slug)
    {:noreply, socket |> assign(error: error(result)) |> reload()}
  end

  def handle_event("ask", %{"query" => query}, socket), do: command(socket, :ask, %{query: query})

  def handle_event("respond", %{"id" => id, "choice" => choice}, socket) do
    requests =
      if socket.assigns.run,
        do: socket.assigns.run.requests,
        else: []

    request = Enum.find(requests, &(&1.id == id))

    if request && choice in Map.get(request.payload, "choices", []) do
      command(socket, :respond, %{interaction_id: id, response: %{choice: choice}})
    else
      {:noreply, assign(socket, error: "This request is no longer available.")}
    end
  end

  def handle_event("todo_add", %{"text" => text}, socket),
    do: command(socket, :todo_add, %{id: Ash.UUIDv7.generate(), text: text})

  def handle_event("todo_complete", %{"id" => id}, socket),
    do: command(socket, :todo_complete, %{id: id, result: "Verified in the playground"})

  def handle_event("todo_block", %{"id" => id}, socket),
    do: command(socket, :todo_block, %{id: id, reason: "Blocked in the playground"})

  def handle_event("todo_remove", %{"id" => id}, socket),
    do: command(socket, :todo_remove, %{id: id})

  def handle_event("cancel_run", _, socket), do: command(socket, :cancel, %{})

  def handle_event("add", %{"amount" => amount}, socket),
    do: command(socket, :add, %{amount: amount})

  def handle_event("add_item", %{"item" => item}, socket),
    do: command(socket, :add, %{item: item})

  def handle_event("complete", %{"item" => item}, socket),
    do: command(socket, :complete, %{item: item})

  def handle_event("append", %{"text" => text}, socket),
    do: command(socket, :append, %{text: text})

  def handle_event("work", %{"text" => text}, socket), do: command(socket, :run, %{text: text})

  def handle_event("team_add", _, socket),
    do:
      command(socket, :send, %{
        data: %{member: :counter, type: "counter.add", payload: %{amount: 1}}
      })

  def handle_event("spawn_squad", _, socket) do
    names = Enum.map(members(socket.assigns.run), & &1.name)
    name = Enum.find(1..4, &("squad-#{&1}" not in names))
    command(socket, :add_member, %{member: "squad-#{name}", template: :squad})
  end

  def handle_event("spawn_node", %{"parent" => parent, "kind" => kind, "name" => name}, socket) do
    socket = assign(socket, tree_parent: parent, tree_kind: kind, tree_name: name)

    kind =
      case kind do
        "agent" -> :agent
        "team" -> :team
      end

    result =
      Playground.command(socket.assigns.owner, socket.assigns.example.slug, :spawn_node, %{
        path: Jason.decode!(parent),
        kind: kind,
        name: name
      })

    socket = if result == :ok, do: assign(socket, tree_name: ""), else: socket
    {:noreply, socket |> assign(error: error(result)) |> reload()}
  end

  def handle_event("tree_settings", params, socket),
    do:
      {:noreply,
       assign(socket,
         tree_parent: params["parent"],
         tree_kind: params["kind"],
         tree_name: params["name"]
       )}

  def handle_event("remove_squad", %{"member" => member}, socket),
    do: command(socket, :remove_member, %{member: member})

  def handle_event("squad_add", %{"member" => member}, socket),
    do:
      command(socket, :send, %{
        data: %{
          member: member,
          type: "aikido.ash.team.send",
          payload: %{member: :counter, type: "counter.add", payload: %{amount: 1}}
        }
      })

  def handle_async(:start_example, {:ok, {:ok, run}}, socket),
    do: {:noreply, assign(socket, run: run, starting: false, error: nil)}

  def handle_async(:start_example, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, starting: false, error: reason)}

  def handle_async(:start_example, {:exit, reason}, socket),
    do: {:noreply, assign(socket, starting: false, error: "Could not start: #{inspect(reason)}")}

  def handle_info({:run_updated, owner, slug}, socket) do
    if owner == socket.assigns.owner && slug == socket.assigns.example.slug,
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  defp ai_default(example, key, fallback) do
    case Ash.Resource.Info.attribute(example.resource, key) do
      nil -> fallback
      attribute -> attribute.default || fallback
    end
  end

  defp reload(socket),
    do: assign(socket, :run, Playground.get(socket.assigns.owner, socket.assigns.example.slug))

  defp command(socket, action, input) do
    result = Playground.command(socket.assigns.owner, socket.assigns.example.slug, action, input)
    {:noreply, socket |> assign(error: error(result)) |> reload()}
  end

  defp error(:ok), do: nil
  defp error({:error, reason}), do: reason
  defp prompt(%{kind: :ai_team}), do: "orchestrate: Signals carry results"
  defp prompt(_), do: "Signals carry results"
  defp active?(nil), do: false
  defp active?(run), do: run.status != :stopped
  defp busy?(run), do: run && run.status == :running
  defp own(nil), do: %{}
  defp own(run), do: run.snapshot.own
  defp result_text(value) when is_binary(value), do: value
  defp result_text(nil), do: ""
  defp result_text(value), do: inspect(value)
  defp members(nil), do: []
  defp members(run), do: run.snapshot.members

  def render(assigns) do
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
      <div class="workspace">
        <div class="primary-column">
          <section :if={!active?(@run)} class="panel" id="start-panel">
            <div class="section-heading">
              <h2>Make it live</h2><span>Your own instance</span>
            </div>
            <form id="start-form" phx-submit="start" phx-change="settings">
              <div :if={Catalog.ai?(@example)} class="settings-grid">
                <label>Model mode<select name="mode"><option
                  value="offline"
                  selected={@mode == "offline"}
                >
                  Offline · scripted model
                </option><option value="live" selected={@mode == "live"}>Live · z.ai</option></select></label>
                <label :if={@mode == "live"}>Model<input
                  name="model"
                  value={@model}
                  placeholder="zai:glm-5.3"
                /></label>
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
                  Offline mode runs real tools without a key. Live mode reads ZAI_API_KEY from the server environment.
                </p>
              </div>
              <button class="button primary" disabled={@starting}>{if @starting,
                do: "Starting…",
                else: "Start example"} <span>→</span></button>
            </form>
          </section>
          <section :if={Catalog.ai?(@example)} class="panel conversation">
            <section :if={active?(@run)} id="hook-requests">
              <article
                :for={request <- @run.requests}
                id={"request-#{request.id}"}
                class="panel"
              >
                <h3>{Map.get(request.payload, "title", request.type)}</h3>
                <pre>{inspect(Map.get(request.payload, "details", request.payload), pretty: true)}</pre>
                <div class="inline-form">
                  <button
                    :for={choice <- Map.get(request.payload, "choices", [])}
                    class="button secondary"
                    phx-click="respond"
                    phx-value-id={request.id}
                    phx-value-choice={choice}
                  >{choice}</button>
                  <button class="button danger" phx-click="cancel_run">Cancel run</button>
                </div>
              </article>
            </section>
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
              :if={
                active?(@run) && busy?(@run) && Map.get(@run.snapshot.ai, :streaming_text, "") != ""
              }
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
                disabled={!active?(@run) || (busy?(@run) && @example.slug != "conversation")}
              >{@prompt}</textarea>
              <button
                class="button primary"
                disabled={!active?(@run) || (busy?(@run) && @example.slug != "conversation")}
              >{if busy?(@run) && @example.slug == "conversation",
                do: "Queue message",
                else: "Send task →"}</button>
            </form>
          </section>
          <section :if={@example.slug == "conversation" && active?(@run)} class="panel" id="todos">
            <h2>Optional todos</h2>
            <p>Completion waits for blocking items. Record evidence, block an item, or remove it.</p>
            <form id="todo-form" phx-submit="todo_add" class="inline-form">
              <input name="text" placeholder="Work to verify" required />
              <button class="button secondary">Add todo</button>
            </form>
            <article :for={item <- @run.snapshot.todos} id={"todo-#{item.id}"}>
              <span>{item.text} · {item.status}</span>
              <button class="button secondary" phx-click="todo_complete" phx-value-id={item.id}>Complete</button>
              <button class="button secondary" phx-click="todo_block" phx-value-id={item.id}>Block</button>
              <button class="button secondary" phx-click="todo_remove" phx-value-id={item.id}>Remove</button>
            </article>
          </section>
          <section :if={@example.kind == :counter} class="panel" id="counter-panel">
            <div class="counter-visual">
              <svg viewBox="0 0 160 160" role="img" aria-label="Counter state"><circle
                cx="80"
                cy="80"
                r="68"
                class="ring-track"
              /><circle
                cx="80"
                cy="80"
                r="68"
                class="ring-value"
                stroke-dasharray={"#{min(abs(own(@run)[:count] || 0), 100) * 4.27} 427"}
              /></svg><div>
                <strong id="counter-value">{own(@run)[:count] || 0}</strong><span>current count</span>
              </div>
            </div>
            <form id="counter-form" phx-submit="add" class="inline-form">
              <label>Amount<input type="number" name="amount" value="1" /></label><button
                class="button primary"
                disabled={!active?(@run)}
              >Add →</button>
            </form>
          </section>
          <section :if={@example.kind == :checklist} class="panel">
            <div class="section-heading">
              <h2>Checklist</h2><span id="completed-count">{own(@run)[:completed] || 0} completed</span>
            </div>
            <div class="progress-track">
              <div style={"width: #{if ((own(@run)[:completed] || 0) + length(own(@run)[:items] || [])) == 0, do: 0, else: round((own(@run)[:completed] || 0) / ((own(@run)[:completed] || 0) + length(own(@run)[:items] || [])) * 100)}%"}>
              </div>
            </div>
            <ul id="checklist" class="checklist">
              <li :for={item <- own(@run)[:items] || []}>
                <span>{item}</span><button
                  phx-click="complete"
                  phx-value-item={item}
                  class="text-button"
                >Complete ✓</button>
              </li>
            </ul>
            <form id="checklist-form" phx-submit="add_item" class="inline-form">
              <label>New item<input name="item" placeholder="Try this example" required /></label><button
                class="button primary"
                disabled={!active?(@run)}
              >Add item</button>
            </form>
          </section>
          <section :if={@example.kind == :notebook} class="panel">
            <div class="section-heading">
              <h2>{own(@run)[:title] || "Notebook"}</h2><span>Embedded journal slice</span>
            </div>
            <div id="journal" class="journal">
              <article :for={
                {entry, index} <- Enum.with_index(if(@run, do: @run.snapshot.journal, else: []))
              }>
                <span>NOTE {index + 1}</span><p>{entry}</p>
              </article>
            </div>
            <form id="notebook-form" phx-submit="append">
              <label>Journal entry<textarea
                name="text"
                rows="3"
                placeholder="What did you discover?"
                required
              ></textarea></label><button class="button primary" disabled={!active?(@run)}>Append note →</button>
            </form>
          </section>
          <section :if={@example.kind == :worker} class="panel">
            <div class="section-heading">
              <h2>Background work</h2><span id="worker-status">{own(@run)[:status] || :idle}</span>
            </div>
            <.flow steps={["Dispatch", "Uppercase task", "Result signal"]} />
            <div id="worker-result" class="result-display">
              {own(@run)[:result] || "Your result will land here."}
            </div>
            <form id="worker-form" phx-submit="work">
              <label>Text to transform<input name="text" value="signals carry results" required /></label><button
                class="button primary"
                disabled={!active?(@run)}
              >Dispatch task →</button>
            </form>
          </section>
          <section
            :if={@example.kind in [:team, :ai_team, :nested_team]}
            class={["panel", @example.kind == :nested_team && "nested-team-panel"]}
          >
            <div class="section-heading">
              <h2>Live topology</h2><span id="member-count">{length(members(@run))} members</span>
            </div>
            <.topology
              members={members(@run)}
              children={if @run, do: @run.snapshot.children, else: %{}}
              orchestrator={@example.kind == :ai_team}
              compact={@example.kind == :nested_team}
            />
            <button
              :if={@example.kind == :team}
              id="team-add"
              phx-click="team_add"
              class="button secondary"
              disabled={!active?(@run)}
            >Send +1 to the counter</button>
            <div :if={@example.kind == :nested_team} id="squad-controls">
              <form id="tree-form" phx-submit="spawn_node" phx-change="tree_settings">
                <label>Parent node<select name="parent"><option
                  :for={{label, value} <- Playground.tree_options(@run)}
                  value={value}
                  selected={value == @tree_parent}
                >
                  {label}
                </option></select></label>
                <label>Child kind<select name="kind"><option
                  value="agent"
                  selected={@tree_kind == "agent"}
                >
                  Agent
                </option><option value="team" selected={@tree_kind == "team"}>
                  Team
                </option></select></label>
                <label>Child name<input name="name" placeholder="helper" value={@tree_name} required /></label>
                <button class="button primary" disabled={!active?(@run)}>Spawn child</button>
              </form>
              <details class="root-team-controls">
                <summary>Root team commands</summary>
                <button
                  id="spawn-squad"
                  phx-click="spawn_squad"
                  class="button primary"
                  disabled={
                    !active?(@run) ||
                      Enum.count(members(@run), &String.starts_with?(&1.name, "squad-")) >= 3
                  }
                >Spawn a subteam</button>
                <div :for={member <- members(@run)} class="inline-form">
                  <strong>{member.name}</strong>
                  <button
                    :if={
                      @run.snapshot.children[member.name] &&
                        @run.snapshot.children[member.name].resource == AgentExamples.Team
                    }
                    phx-click="squad_add"
                    phx-value-member={member.name}
                    class="button secondary"
                  >Send +1 through {member.name}</button>
                  <button
                    :if={member.dynamic}
                    phx-click="remove_squad"
                    phx-value-member={member.name}
                    class="button danger"
                  >Remove {member.name}</button>
                </div>
              </details>
            </div>
            <div :if={@run && @run.snapshot.tasks != []} class="task-list" id="tasks">
              <h3>Delegated work</h3><div :for={task <- @run.snapshot.tasks}>
                <strong>{task.member}</strong><span class="status-pill">{task.status}</span><p>
                  {result_text(task.result)}
                </p>
              </div>
            </div>
          </section>
        </div>
        <aside class="inspector">
          <section :if={@example.slug in ["hooks", "hook-requests"]} class="panel" id="hook-inspector">
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
end
