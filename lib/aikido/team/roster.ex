defmodule Aikido.Team.Roster do
  @moduledoc "Retains native membership facts and atomically bootstraps roster followers."
  alias Aikido.Thread.{Followers, Journal}

  def record({:ok, %{membership_journal: nil} = state, directives}, _previous, _context),
    do: {:ok, state, directives}

  def record({:ok, state, directives}, previous, context) do
    case member_entries(previous, state, context) do
      [] -> {:ok, state, directives}
      entries -> record_entries(state, directives, entries, context)
    end
  end

  def record(error, _previous, _context), do: error

  defp record_entries(state, directives, entries, context) do
    with {:ok, journal} <- Journal.append(state.membership_journal, entries, context.signal) do
      {journal, deliveries} = Followers.offer_all(journal, context, :roster)
      changes = Journal.changes(state.membership_journal, journal)
      state = if changes == %{}, do: state, else: Map.put(state, :membership_journal, changes)
      {:ok, state, directives ++ deliveries}
    end
  end

  def bootstrap(state, context) do
    journal = state.membership_journal

    if is_nil(journal) do
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :path,
         message:
           "Roster history is disabled. Use the owning configure_roster_replay command to enable a retained team, or configure `roster_history? true` before initial startup."
       )}
    else
      if Journal.next_sequence(journal) == 0 do
        entry = bootstrap_entry(state, context)

        Journal.append(journal, [entry], context.signal)
      else
        {:ok, journal}
      end
    end
  end

  @doc "Sparse native creation input that atomically records the current topology when enabling replay."
  def initial_journal(state, metadata, context) do
    now = Aikido.Signal.timestamp(context.signal)

    entry =
      bootstrap_entry(state, context)
      |> Map.merge(%{
        seq: 0,
        at: now,
        refs: %{
          signal_id: context.signal.id,
          signal_type: context.signal.type,
          signal_time: now
        }
      })
      |> Aikido.Thread.Types.Entry.new!()

    with {:ok, receipt} <- Aikido.Thread.EntryReceipts.from_entry(entry) do
      {:ok,
       %{
         id: "team-membership",
         replay?: true,
         metadata: metadata,
         entries: [entry],
         entry_receipts: [receipt],
         rev: 1,
         next_sequence: 1,
         updated_at: now,
         stats: %{entry_count: 1}
       }}
    end
  end

  defp bootstrap_entry(state, context) do
    members =
      Enum.map(state.topology.nodes, fn {name, spec} -> member(name, spec, state, context) end)

    %{
      id: "#{context.signal.id}/roster",
      kind: :roster,
      payload: %{event: :bootstrap, members: members}
    }
  end

  defp member_entries(previous, current, context) do
    names =
      (Map.keys(previous.topology.nodes) ++ Map.keys(current.topology.nodes))
      |> Enum.uniq()
      |> Enum.sort()

    names
    |> Enum.with_index()
    |> Enum.flat_map(fn {name, index} ->
      before = previous.topology.nodes[name]
      after_spec = current.topology.nodes[name]

      event =
        cond do
          is_nil(after_spec) ->
            :removed

          is_nil(before) ->
            :added

          before.resource != after_spec.resource ->
            :replaced

          previous.members[name] != current.members[name] && is_nil(current.members[name]) ->
            :stopped

          previous.members[name] != current.members[name] ->
            :started

          previous.incarnations[name] != current.incarnations[name] ->
            :started

          true ->
            nil
        end

      if event do
        spec = after_spec || before

        payload = member(name, spec, current, context) |> Map.put(:event, event)

        payload =
          case {event, previous.members[name]} do
            {:stopped, pid} when is_pid(pid) ->
              Map.put(payload, :reference, reference(name, before.resource, previous, context))

            {:removed, pid} when is_pid(pid) ->
              Map.put(payload, :reference, reference(name, before.resource, previous, context))

            {:replaced, _} ->
              old_resource =
                case previous.members[name] do
                  %{resource: resource} -> resource
                  _ -> before.resource
                end

              Map.put(
                payload,
                :previous_reference,
                reference(name, old_resource, previous, context)
              )

            _ ->
              payload
          end

        [%{id: "#{context.signal.id}/member/#{index}", kind: :membership, payload: payload}]
      else
        []
      end
    end)
  end

  defp member(name, spec, state, context) do
    reference = reference(name, spec.resource, state, context)
    active? = is_pid(state.members[name])

    %{
      name: name,
      reference: reference,
      owner: spec.owner,
      active?: active?,
      incarnation: if(active?, do: state.incarnations[name]),
      team?: not is_nil(Aikido.Agent.Info.team_config(spec.resource))
    }
  end

  defp reference(name, resource, state, context) do
    Aikido.Agent.Reference.new!(
      id: Aikido.Team.Topology.member_id(state.topology, context.agent_id, name),
      resource: resource,
      aikido: context.aikido,
      partition: context.partition
    )
  end
end
