defmodule Aikido.Ownership.Monitors do
  @moduledoc "Builds release directives for retired ownership bindings."
  def release(%{ref: ref}) when is_reference(ref), do: [%Aikido.Directives.Demonitor{ref: ref}]
  def release(_), do: []
end
