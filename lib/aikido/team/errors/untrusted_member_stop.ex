defmodule Aikido.Team.Errors.UntrustedMemberStop do
  @moduledoc "A member stop result arrived outside its native correlated delivery."
  use Splode.Error, class: :forbidden, fields: []

  def message(_error) do
    "Member stop acknowledgement requires the current receiver-owned lifecycle delivery. " <>
      "A member name, PID or operation ID alone is not proof that cleanup succeeded."
  end
end
