defmodule Aikido.Team.Errors.UntrustedInheritance do
  @moduledoc "Inherited configuration arrived outside its current native team delivery."
  use Splode.Error, class: :forbidden, fields: []

  def message(_error) do
    "Inherited configuration requires the current team's runtime-correlated delivery. " <>
      "Use the owning reconcile_inherited command; a member name and operation ID do not authenticate an inheritance request or acknowledgement."
  end
end
