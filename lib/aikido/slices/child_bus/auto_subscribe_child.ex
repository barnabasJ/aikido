defmodule Aikido.Slices.ChildBus.AutoSubscribeChild do
  @moduledoc "Action invoked by `Aikido.Slices.ChildBus` on every `aikido.agent.child.started`\nsignal the host agent receives.\n\nReads the child's module and pid out of the signal data, pulls the\ntarget bus out of the `:child_bus` slice, and emits one\nsubscribe-child directive per path\ndeclared by the child's `signal_routes/0`. The directive performs\nthe actual `Jido.Signal.Bus.subscribe/3` I/O and casts a\n`\"child_bus.subscribed\"` (or `\"child_bus.subscribe_failed\"`) signal\nback to the agent; the cascade actions\n`Aikido.Slices.ChildBus.RecordSubscription` /\n`RecordSubscriptionFailure` settle the result onto the slice. This\naction itself is pure — it returns the slice unchanged and a\ndirective list.\n\nThe host agent's `maybe_track_child_started/2`\nstill runs on the same signal and is responsible for putting the\nchild in `state.children` — this action is purely additive.\n"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{
              name: "child_bus_auto_subscribe_child",
              description: "Emit subscribe directives for each of a child's signal_routes."
            }}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :pid, :term, allow_nil?: false
      argument :child_module, :atom, allow_nil?: false
      argument :tag, :term, allow_nil?: false
      argument :parent_id, :string, allow_nil?: true
      argument :child_id, :string, allow_nil?: true
      argument :child_partition, :term, allow_nil?: true
      argument :meta, :map, allow_nil?: true
      description "Emit subscribe directives for each of a child's signal_routes."

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
  alias Aikido.Slices.ChildBus.Directives.SubscribeChild

  defp reduce(%Jido.Signal{data: params}, slice, _opts, _ctx) do
    with {:ok, bus} <- fetch_bus(slice),
         {:ok, routes} <- fetch_routes(params.child_module) do
      directives =
        Enum.map(routes, fn route ->
          %SubscribeChild{
            bus: bus,
            tag: params.tag,
            path: elem(route, 0),
            target_pid: params.pid,
            child_module: params.child_module
          }
        end)

      {:ok, slice, directives}
    else
      {:error, reason} ->
        Logger.warning("child_bus: skipped auto-subscribe — #{reason}")
        {:ok, slice, []}
    end
  end

  defp fetch_bus(slice) do
    case Map.get(slice, :bus) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, "no :bus configured under :child_bus slice"}
    end
  end

  defp fetch_routes(child_module) do
    if Spark.Dsl.is?(child_module, Aikido.Slice) do
      {:ok, Aikido.Dsl.Slice.Info.signal_routes(child_module)}
    else
      {:error, "#{inspect(child_module)} is not a Aikido.Slice"}
    end
  end
end
