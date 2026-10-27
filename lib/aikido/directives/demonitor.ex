defmodule Aikido.Directives.Demonitor do
  @moduledoc "Releases a retired process monitor."
  use Aikido.Directive

  typed_struct do
    field :ref, :term do
      description "Monitor reference belonging to the retired process."
      allow_nil? false
    end
  end

  @impl true
  def exec(%{ref: ref}, _signal, _runtime) do
    Process.demonitor(ref, [:flush])
    :ok
  end
end
