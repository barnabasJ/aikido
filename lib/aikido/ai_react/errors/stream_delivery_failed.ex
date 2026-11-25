defmodule Aikido.AiReact.Errors.StreamDeliveryFailed do
  @moduledoc "A stream batch was rejected or its adoption acknowledgement became ambiguous."
  use Splode.Error, fields: [:reason, retryable?: false], class: :api

  def message(error),
    do: "Stream batch delivery failed (#{error.reason}); it will not be retried."
end
