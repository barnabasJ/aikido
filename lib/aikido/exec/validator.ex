defmodule Aikido.Exec.Validator do
  @moduledoc false
  alias Aikido.Action.Error

  def validate_action(reference) do
    if Aikido.ActionRef.valid?(reference),
      do: :ok,
      else: {:error, Error.validation_error("Invalid native Ash action: #{inspect(reference)}")}
  end

  # Ash.ActionInput owns parameter validation, preparations and defaults at dispatch.
  def validate_params(_reference, params), do: {:ok, params}
  def validate_output(_reference, output, _opts), do: {:ok, output}
end
