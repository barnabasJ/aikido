defmodule Aikido.Agent.SliceValidationError do
  @moduledoc """
  Raised during the native `:initialize` action when a slice's seeded value fails schema
  validation. The exception carries the offending path, the slice module
  (or `nil` for the agent's own slice), and the underlying Ash errors.
  """

  defexception [:path, :module, :errors, message: "slice validation failed"]

  @impl true
  def exception(opts) do
    path = opts[:path]
    module = opts[:module]
    errors = opts[:errors] || []

    label =
      cond do
        module != nil -> "slice #{inspect(module)} at path #{inspect(path)}"
        path != nil -> "slice at path #{inspect(path)}"
        true -> "agent slice"
      end

    detail = inspect(errors)

    %__MODULE__{
      path: path,
      module: module,
      errors: errors,
      message: "Slice validation failed for #{label}: #{detail}"
    }
  end
end
