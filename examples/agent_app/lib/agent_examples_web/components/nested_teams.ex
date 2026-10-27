defmodule AgentExamplesWeb.Components.NestedTeams do
  @moduledoc "Reusable nested teams controls and command hook."
  use Phoenix.Component
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     attach_hook(
       assign(socket, tree_parent: "[]", tree_kind: "agent", tree_name: ""),
       :nested_teams_commands,
       :handle_event,
       &handle_event/3
     )}
  end

  defp handle_event("spawn_squad", _, socket) do
    names = Enum.map(members(socket.assigns.run), & &1.name)
    name = Enum.find(1..4, &("squad-#{&1}" not in names))
    ExamplePage.command(socket, :add_member, %{member: "squad-#{name}", template: :squad})
  end

  defp handle_event("spawn_node", %{"parent" => parent, "kind" => kind, "name" => name}, socket) do
    socket = assign(socket, tree_parent: parent, tree_kind: kind, tree_name: name)

    kind =
      case kind do
        "agent" -> :agent
        "team" -> :team
      end

    {:halt, socket} =
      ExamplePage.command(socket, :spawn_node, %{
        path: Jason.decode!(parent),
        kind: kind,
        name: name
      })

    socket = if is_nil(socket.assigns.error), do: assign(socket, tree_name: ""), else: socket
    {:halt, socket}
  end

  defp handle_event("tree_settings", params, socket),
    do:
      {:halt,
       assign(socket,
         tree_parent: params["parent"],
         tree_kind: params["kind"],
         tree_name: params["name"]
       )}

  defp handle_event("remove_squad", %{"member" => member}, socket),
    do: ExamplePage.command(socket, :remove_member, %{member: member})

  defp handle_event("squad_add", %{"member" => member}, socket),
    do:
      ExamplePage.command(socket, :send, %{
        member: member,
        type: "aikido.ash.team.send",
        payload: %{member: :counter, type: "counter.add", payload: %{amount: 1}}
      })

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true
  attr :team_trees, :map, default: %{}
  attr :tree_parent, :string, default: "[]"
  attr :tree_kind, :string, default: "agent"
  attr :tree_name, :string, default: ""

  def nested_teams(assigns) do
    ~H"""
    <.team_topology tree_states={@team_trees} run={@run} compact>
      <div id="squad-controls">
        <form id="tree-form" phx-submit="spawn_node" phx-change="tree_settings">
          <label>Parent node<select name="parent"><option
            :for={{label, value} <- AgentExamples.Playground.tree_options(@run)}
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
    </.team_topology>
    """
  end
end
