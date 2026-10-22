defmodule AgentExamplesWeb.Components do
  use Phoenix.Component
  alias AgentExamples.Catalog

  attr :active, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :examples, Catalog.all())

    ~H"""
    <div class="app-shell">
      <aside class="sidebar">
        <.link navigate="/" class="brand"><span class="brand-icon">A</span>
        Aikido <span class="brand-tag">playground</span></.link>
        <p class="nav-heading">EXPLORE THE EXAMPLES</p>
        <nav aria-label="Examples">
          <.link
            :for={example <- @examples}
            navigate={"/examples/#{example.slug}"}
            class={["nav-link", @active == example.slug && "active"]}
          >
            <span class="nav-dot"></span>{example.title}
          </.link>
        </nav>
        <div class="sidebar-note">
          <span class="live-dot"></span>
          Live, local, and inspectable<p>
            Real agents. Real signals.<br />A little room to experiment.
          </p>
        </div>
      </aside>
      <main class="main-content">{render_slot(@inner_block)}</main>
    </div>
    """
  end

  attr :steps, :list, required: true

  def flow(assigns) do
    ~H"""
    <div class="flow" aria-label="How this example works">
      <div :for={{step, index} <- Enum.with_index(@steps)} class="flow-step">
        <span class="step-number">{index + 1}</span><span>{step}</span>
      </div>
    </div>
    """
  end

  attr :members, :list, required: true
  attr :children, :map, default: %{}
  attr :orchestrator, :boolean, default: false
  attr :owner, :any, default: nil
  attr :compact, :boolean, default: false

  def topology(assigns) do
    ~H"""
    <div class={["topology", @compact && "compact-tree"]} aria-label="Live team topology">
      <div :if={is_nil(@owner)} class="topology-root">
        <span class="live-dot"></span>{if @orchestrator,
          do: "AI orchestrator",
          else: "Team supervisor"}<small>one public interface</small>
      </div>
      <div class="tree-trunk"></div>
      <div class="member-grid">
        <div
          :for={member <- Enum.filter(@members, &(&1.owner == @owner))}
          data-node={member.name}
          class={["member-node", member.owner && "subworker"]}
        >
          <span class="node-kind">{cond do
            @children[member.name] && @children[member.name].team? ->
              if member.dynamic, do: "DYNAMIC SUBTEAM", else: "FIXED SUBTEAM"

            member.owner ->
              "DYNAMIC SUBWORKER"

            member.dynamic ->
              "DYNAMIC WORKER"

            true ->
              "FIXED MEMBER"
          end}</span>
          <strong>{member.name}</strong>
          <small>{if member.owner, do: "↳ owned by #{member.owner}", else: "↳ owned by the team"}</small>
          <code :if={@children[member.name]} class="member-state">{inspect(@children[member.name].own)}</code>
          <span class="node-status">{if member.alive, do: "● Running", else: "○ Stopped"}</span>
          <.topology
            :if={@children[member.name] && @children[member.name].members != []}
            members={@children[member.name].members}
            children={@children[member.name].children}
            compact={@compact}
          />
          <.topology
            :if={Enum.any?(@members, &(&1.owner == member.name))}
            members={@members}
            children={@children}
            owner={member.name}
            compact={@compact}
          />
        </div>
      </div>
      <p :if={@members == []} class="muted center">
        Start the example to bring this topology to life.
      </p>
    </div>
    """
  end
end
