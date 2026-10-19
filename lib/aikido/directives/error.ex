defmodule Aikido.Directives.Error do
  @moduledoc """
  Signal an error from agent command processing.

  This directive carries a `Aikido.Error.t()` for consistent error handling.
  The runtime can log, emit, or handle errors based on this directive.

  ## Fields

  - `error` - A `Aikido.Error.t()` struct
  - `context` - Optional atom describing error context (e.g., `:normalize`, `:instruction`)
  """

  use Aikido.Directive

  typed_struct do
    field :error, :term, allow_nil?: false, description: "Aikido.Error struct"
    field :context, :atom, allow_nil?: true, description: "Error context"
  end

  # Error directives log and continue. Users who need stop-on-error or
  # max-errors semantics write a small middleware that pattern-matches on
  # `%Directives.Error{}` in the chain result.

  require Logger

  @impl true
  def exec(%Aikido.Directives.Error{error: error, context: context}, _input_signal, state) do
    Logger.error("Agent #{state.id}#{format_context(context)}: #{format_error(error)}")

    :ok
  end

  defp format_context(nil), do: ""
  defp format_context(ctx), do: " [#{ctx}]"

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error), do: inspect(error)
end
