defmodule Aikido.Slices.ChildBus.AutoSubscribeChild do
  @moduledoc """
  Action invoked by `Aikido.Slices.ChildBus` on every `aikido.agent.child.started`
  signal the host agent receives.

  Reads the child's module and pid out of the signal data, pulls the
  target bus out of the `:child_bus` slice, and emits one
  subscribe-child directive per path
  declared by the child's `signal_routes/0`. The directive performs
  the actual `Jido.Signal.Bus.subscribe/3` I/O and casts a
  `"child_bus.subscribed"` (or `"child_bus.subscribe_failed"`) signal
  back to the agent; the cascade actions
  `Aikido.Slices.ChildBus.RecordSubscription` /
  `RecordSubscriptionFailure` settle the result onto the slice. This
  action itself is pure — it returns the slice unchanged and a
  directive list.

  The host agent's `maybe_track_child_started/2`
  still runs on the same signal and is responsible for putting the
  child in `state.children` — this action is purely additive.
  """

  use Aikido.Action

  action do
    name "child_bus_auto_subscribe_child"
    description "Emit subscribe directives for each of a child's signal_routes."

    schema do
      attribute :pid, :term, allow_nil?: false
      attribute :child_module, :atom, allow_nil?: false
      attribute :tag, :term, allow_nil?: false
      attribute :parent_id, :string, allow_nil?: true
      attribute :child_id, :string, allow_nil?: true
      attribute :child_partition, :term, allow_nil?: true
      attribute :meta, :map, allow_nil?: true
    end
  end

  require Logger

  alias Aikido.Slices.ChildBus.Directives.SubscribeChild

  def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
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
