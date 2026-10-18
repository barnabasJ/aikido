defmodule Aikido.Slices.ChildBus.AutoUnsubscribeChild do
  @moduledoc "Action invoked by `Aikido.Slices.ChildBus` on every `aikido.agent.child.exit`\nsignal the host agent receives (emitted by\n`AgentServer.handle_child_down/3` when a monitored child process\ndies).\n\nLooks up the subscription ids previously stored by\n`Aikido.Slices.ChildBus.RecordSubscription` for this tag, removes the\nentry from the slice, and emits one\nunsubscribe-child directive per\nsub_id. The directive performs the actual `Jido.Signal.Bus.unsubscribe/2`\nI/O. This action itself is pure — its only outputs are its return\nvalue (slice with the tag removed + directive list).\n"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{
              name: "child_bus_auto_unsubscribe_child",
              description: "Drop a child's subscription tracking and emit unsubscribe directives."
            }}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :pid, :term, allow_nil?: true
      argument :reason, :term, allow_nil?: true
      description "Drop a child's subscription tracking and emit unsubscribe directives."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  require Logger
  alias Aikido.Slices.ChildBus.Directives.UnsubscribeChild

  defp reduce(%Jido.Signal{data: %{tag: tag}}, slice, _opts, _ctx) do
    with {:ok, bus} <- fetch_bus(slice),
         sub_ids when is_list(sub_ids) <- get_in(slice, [:subscriptions, tag]) do
      directives = Enum.map(sub_ids, &%UnsubscribeChild{bus: bus, sub_id: &1, tag: tag})
      subscriptions = Map.delete(Map.get(slice, :subscriptions, %{}), tag)
      {:ok, Map.put(slice, :subscriptions, subscriptions), directives}
    else
      _ ->
        Logger.debug("child_bus: no subscriptions tracked for #{inspect(tag)}, skipping")
        {:ok, slice, []}
    end
  end

  defp fetch_bus(slice) do
    case Map.get(slice, :bus) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, :no_bus}
    end
  end
end
