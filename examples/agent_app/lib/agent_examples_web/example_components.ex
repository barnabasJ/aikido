defmodule AgentExamplesWeb.ExampleComponents do
  @moduledoc "Shared framing, conversation and topology visuals for the example pages."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1, status_pill: 1]
  import AgentExamplesWeb.Components
  import AgentExamplesWeb.Markdown

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
  attr :inspection_selected, :any, default: nil
  attr :inspection_view, :string, default: "diff"
  attr :inspection_format, :string, default: "tree"
  attr :inspection_filter, :string, default: ""
  attr :show_signal_activity, :boolean, default: true
  slot :inner_block, required: true
  slot :inspector

  def page(assigns) do
    ~H"""
    <.shell active={@example.slug}>
      <AgentExamplesWeb.Components.ExampleHeader.example_header {assigns} />
      <section class="panel overview">
        <p>{@example.detail}</p><.flow steps={@example.flow} />
      </section>
      <div :if={@error || (@run && @run.error)} role="alert" id="error" class="error-banner">
        {@error || @run.error}
      </div>
      <AgentExamplesWeb.Components.ProviderSettings.provider_settings {assigns} />
      <div class="workspace">
        <div class="primary-column">
          <AgentExamplesWeb.Components.StartControls.start_controls {assigns} />
          {render_slot(@inner_block)}
        </div>
        <aside class="inspector">
          {render_slot(@inspector)}
          <AgentExamplesWeb.Components.RuntimeDetails.runtime_details {assigns} />
          <.delegated_work run={@run} />
          <.signal_activity :if={@show_signal_activity} run={@run} />
        </aside>
      </div>
      <Aikido.Inspector.Components.inspector
        history={@run && @run.inspection}
        selected={@inspection_selected}
        view={@inspection_view}
        format={@inspection_format}
        filter={@inspection_filter}
      />
      <AgentExamplesWeb.Components.SourceDefinitions.source_definitions {assigns} />
      <footer class="page-footer">
        Instances stay available while the server runs. Stop an example to release its processes.
      </footer>
    </.shell>
    """
  end

  attr :run, :any, required: true

  def delegated_work(assigns) do
    tasks = if assigns.run, do: collect_delegated_tasks(assigns.run.snapshot, []), else: []
    assigns = assign(assigns, :tasks, Enum.sort_by(tasks, & &1.id, :desc))

    ~H"""
    <section :if={@tasks != []} class="panel delegated-work" id="tasks">
      <.section_heading>
        <:title>Delegated work</:title>
        <span>{length(@tasks)} tasks across the tree</span>
      </.section_heading>
      <div class="delegated-work-scroll">
        <.delegated_task :for={task <- @tasks} task={task} />
      </div>
    </section>
    """
  end

  defp collect_delegated_tasks(snapshot, path) do
    own_tasks =
      Enum.map(snapshot[:tasks] || [], fn task ->
        Map.merge(task, %{
          team_path: Jason.encode!(path),
          owner_path: if(path == [], do: "Root team", else: Enum.join(path, " / ")),
          member_path: Enum.join(path ++ [to_string(task.member)], " / ")
        })
      end)

    child_tasks =
      Enum.flat_map(snapshot[:children] || %{}, fn {name, child} ->
        collect_delegated_tasks(child, path ++ [name])
      end)

    own_tasks ++ child_tasks
  end

  attr :run, :any, required: true

  def signal_activity(assigns) do
    ~H"""
    <section class="panel" id="signal-activity">
      <.section_heading>
        <:title>Signal activity</:title>
        <span>Latest first · UTC</span>
      </.section_heading><p :if={!@run || @run.events == []} class="muted">
        Signals will appear here as you interact.
      </p><ol id="events" class="events">
        <li :for={event <- if(@run, do: Enum.take(@run.events, 20), else: [])}>
          <span>{event.time}</span><code>{event.type}</code>
        </li>
      </ol>
    </section>
    """
  end

  attr :run, :any, required: true
  attr :orchestrator, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :tree_states, :map, default: %{}
  slot :inner_block

  def team_topology(assigns) do
    ~H"""
    <section class={["panel", @compact && "nested-team-panel"]}>
      <.section_heading>
        <:title>Live topology</:title>
        <span id="member-count">{length(members(@run))} members</span>
      </.section_heading>
      <AgentExamplesWeb.TeamTree.tree
        id="team-tree"
        run={@run}
        root_name={if @orchestrator, do: "Orchestrator", else: "Team"}
        selection={@tree_states["team-tree"] || %{}}
      />
      {render_slot(@inner_block)}
    </section>
    """
  end

  def active?(nil), do: false
  def active?(run), do: run.status != :stopped

  def busy?(run) do
    run &&
      (run.status == :running ||
         get_in(run, [:snapshot, :ai, :status]) in [:setup, :running, :waiting])
  end

  def own(nil), do: %{}
  def own(run), do: run.snapshot.own
  def members(nil), do: []
  def members(run), do: run.snapshot.members
  defp result_text(value) when is_binary(value), do: value
  defp result_text(nil), do: ""
  defp result_text(value), do: inspect(value)

  attr :task, :map, required: true

  def delegated_task(assigns) do
    ~H"""
    <details data-owner={@task.owner_path}>
      <summary>
        <strong>{@task.member_path}</strong><.status_pill>
          {if @task.result == :timeout,
            do: "Timed out",
            else: @task.status}
        </.status_pill>
      </summary>
      <p class="muted">Dispatched by {@task.owner_path} · Task ID: {@task.id}</p>
      <p :if={@task[:mode]} class="muted">
        {@task.mode} · Requested by {@task[:requester] || "external caller"}
      </p>
      <button
        :if={@task.status == :dispatched && @task[:mode] == :foreground}
        type="button"
        class="button"
        phx-click="background_task"
        phx-value-task-id={@task.id}
        phx-value-team-path={@task.team_path}
      >
        Continue in background
      </button>
      <.markdown text={
        if @task.result == :timeout,
          do: "The delegated task exceeded its deadline.",
          else: result_text(@task.result)
      } />
    </details>
    """
  end
end
