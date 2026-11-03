defmodule Aikido.Thread.Errors.UntrustedDelivery do
  @moduledoc "A private journal reply arrived outside its runtime-correlated delivery path."
  use Splode.Error, class: :forbidden, fields: []

  def message(_error) do
    "Journal replies require runtime-correlated source delivery. Use the public Follow or Watch command; a source address and request ID do not authenticate a private reply."
  end
end
