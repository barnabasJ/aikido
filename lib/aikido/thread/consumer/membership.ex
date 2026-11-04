defmodule Aikido.Thread.Consumer.Membership do
  @moduledoc "Discovers sources from retained native roster facts and static resource metadata."
  alias Aikido.Thread.Consumer.Types.Source

  def bootstrap_roots(state, context) do
    roots = state.roots ++ parent_root(state, context)
    Enum.reduce(roots, state, &watch_resource(&2, &1, context))
  end

  def apply_entries(state, entries, context) do
    Enum.reduce_while(entries, {:ok, state}, fn entry, {:ok, current} ->
      case apply_entry(current, entry, context) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  def watch_resource(state, reference, context) do
    own =
      Aikido.Agent.Reference.new!(
        id: context.agent_id,
        resource: context.agent_module,
        aikido: context.aikido,
        partition: context.partition
      )

    if reference == own do
      state
    else
      state =
        Enum.reduce(Aikido.Agent.Info.slice_instances(reference.resource), state, fn
          %{module: Aikido.Thread.Slice, path: path}, current ->
            add(current, reference, path, :thread)

          %{module: Aikido.Team.Slice, path: path}, current ->
            if Aikido.Agent.Info.team_config(reference.resource)[:roster_history?],
              do: add(current, reference, path, :roster),
              else: current

          _mount, current ->
            current
        end)

      state
    end
  end

  def add(state, reference, path, channel) do
    case Enum.find(
           state.sources,
           &(&1.source == reference && &1.path == path && &1.channel == channel)
         ) do
      nil ->
        %{
          state
          | sources:
              state.sources ++ [Source.new!(source: reference, path: path, channel: channel)]
        }

      existing ->
        source = %{
          existing
          | retired?: false,
            status:
              if(existing.status in [:unavailable, :watching], do: :ready, else: existing.status)
        }

        %{state | sources: Enum.map(state.sources, &if(&1 == existing, do: source, else: &1))}
    end
  end

  defp apply_entry(state, %{kind: :roster, payload: payload}, context) do
    with {:ok, roster} <- Aikido.Team.Types.RosterBootstrap.new(payload) do
      {:ok, Enum.reduce(roster.members, state, &apply_member(&2, &1, context))}
    end
  end

  defp apply_entry(state, %{kind: :membership, payload: payload}, context) do
    with {:ok, member} <- Aikido.Team.Types.Membership.new(payload) do
      {:ok, apply_member(state, member, context)}
    end
  end

  defp apply_entry(state, _entry, _context), do: {:ok, state}

  defp apply_member(state, %{event: event, reference: reference}, _context)
       when event in [:removed, :stopped] do
    retire_resource(state, reference)
  end

  defp apply_member(state, member, context) do
    state =
      if member.previous_reference,
        do: retire_resource(state, member.previous_reference),
        else: state

    if member.active?,
      do: watch_resource(state, member.reference, context),
      else: retire_resource(state, member.reference)
  end

  defp retire_resource(state, reference) do
    %{
      state
      | sources:
          Enum.map(state.sources, fn source ->
            if source.source == reference,
              do: %{
                source
                | retired?: true,
                  status: if(source.status == :watching, do: :ready, else: source.status)
              },
              else: source
          end)
    }
  end

  defp parent_root(%{follow_parent?: false}, _context), do: []

  defp parent_root(_state, %{parent: %{meta: %{team_id: id, team_resource: resource}}} = context) do
    [
      Aikido.Agent.Reference.new!(
        id: id,
        resource: resource,
        aikido: context.aikido,
        partition: context.partition
      )
    ]
  end

  defp parent_root(_state, _context), do: []
end
