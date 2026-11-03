defmodule Aikido.Notifications.Calculations.SignalType do
  @moduledoc "Exposes the triggering signal type to native Ash PubSub topic templates."
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _options, context) do
    signal = get_in(context.source_context, [:aikido, :signal])
    Enum.map(records, fn _record -> if signal, do: signal.type end)
  end
end
