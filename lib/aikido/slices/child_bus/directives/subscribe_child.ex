defmodule Aikido.Slices.ChildBus.Directives.SubscribeChild do
  @moduledoc false

  @type t :: %__MODULE__{
          bus: atom(),
          tag: any(),
          path: String.t(),
          target_pid: pid(),
          child_module: module()
        }

  use Aikido.Directive

  typed_struct do
    field :bus, :atom, allow_nil?: false
    field :tag, :term, allow_nil?: false
    field :path, :string, allow_nil?: false
    field :target_pid, :term, allow_nil?: false
    field :child_module, :module, allow_nil?: false
  end

  require Logger

  alias Aikido.AgentServer
  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Aikido.Slices.ChildBus.Directives.SubscribeChild

  @impl true
  def exec(%SubscribeChild{} = d, _input_signal, state) do
    case Bus.subscribe(d.bus, d.path, dispatch: {:pid, target: d.target_pid}) do
      {:ok, sub_id} ->
        Logger.debug(
          "child_bus: subscribed #{inspect(d.child_module)}/#{inspect(d.tag)} to #{inspect(d.path)} on #{inspect(d.bus)}"
        )

        signal =
          Signal.new!(
            "child_bus.subscribed",
            %{tag: d.tag, sub_id: sub_id, path: d.path},
            source: "/agent/#{state.id}"
          )

        _ = AgentServer.cast(self(), signal)

      {:error, reason} ->
        Logger.warning(
          "child_bus: failed to subscribe #{inspect(d.child_module)} to #{inspect(d.path)} on #{inspect(d.bus)}: #{inspect(reason)}"
        )

        signal =
          Signal.new!(
            "child_bus.subscribe_failed",
            %{
              tag: d.tag,
              path: d.path,
              reason: reason,
              child_module: d.child_module
            },
            source: "/agent/#{state.id}"
          )

        _ = AgentServer.cast(self(), signal)
    end

    :ok
  end
end
