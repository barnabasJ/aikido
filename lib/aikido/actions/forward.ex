defmodule Aikido.Actions.Forward do
  @moduledoc """
  Pure reducer that forwards the current signal to `target_pid`.

  Optional `signal_type`, `payload` and `source` override the outgoing envelope.
  Returns the supplied state and an `Emit` directive; delivery happens later.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    directive =
      input.context.aikido.signal
      |> apply_forwarding_overrides(input.arguments)
      |> Aikido.Directives.emit_to_pid(input.arguments.target_pid)

    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
  end

  defp apply_forwarding_overrides(original, arguments) do
    changes = %{
      type: resolve_type(arguments[:signal_type], original),
      data: resolve_payload(arguments[:payload], original),
      source: resolve_source(arguments[:source], original)
    }

    case original do
      %Aikido.Signal{} -> Map.merge(original, changes)
      _ -> %Aikido.Signal{type: changes.type, data: changes.data, source: changes.source}
    end
  end

  defp resolve_type(type, _original) when is_binary(type) do
    type
  end

  defp resolve_type(nil, %{type: type}) when is_binary(type) do
    type
  end

  defp resolve_type(nil, _original) do
    "forwarded"
  end

  defp resolve_payload(payload, _original) when is_map(payload) do
    payload
  end

  defp resolve_payload(nil, %{data: data}) do
    data
  end

  defp resolve_payload(nil, _original) do
    %{}
  end

  defp resolve_source(source, _original) when is_binary(source) do
    source
  end

  defp resolve_source(nil, %{source: original_source}) when is_binary(original_source) do
    original_source <> "/forwarded"
  end

  defp resolve_source(nil, _original) do
    "/forwarded"
  end
end
