defmodule Aikido.AiReact.Errors.EffectReceiptLost do
  @moduledoc "An I/O attempt ended before an outstanding effect's receipt was confirmed."
  use Splode.Error,
    fields: [
      :cause_type,
      :status,
      :timeout_phase,
      :transport_type,
      :transport_reason,
      retryable?: false
    ],
    class: :api

  def message(_error), do: "Effect adoption is unconfirmed; the attempt will not be retried."
end
