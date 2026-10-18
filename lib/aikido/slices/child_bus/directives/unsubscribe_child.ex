defmodule Aikido.Slices.ChildBus.Directives.UnsubscribeChild do
  @moduledoc false

  @type t :: %__MODULE__{bus: atom(), sub_id: any(), tag: any()}

  use Aikido.Directive

  typed_struct do
    field :bus, :atom, allow_nil?: false
    field :sub_id, :term, allow_nil?: false
    field :tag, :term, allow_nil?: false
  end

  require Logger

  alias Jido.Signal.Bus
  alias Aikido.Slices.ChildBus.Directives.UnsubscribeChild

  @impl true
  def exec(%UnsubscribeChild{} = d, _input_signal, _state) do
    case Bus.unsubscribe(d.bus, d.sub_id) do
      :ok ->
        Logger.debug("child_bus: unsubscribed #{inspect(d.tag)} sub=#{inspect(d.sub_id)}")

      {:error, reason} ->
        Logger.warning(
          "child_bus: failed to unsubscribe #{inspect(d.tag)} sub=#{inspect(d.sub_id)}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
