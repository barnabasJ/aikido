defmodule Aikido.Actions.Forward do
  @moduledoc """
  Pure reducer that forwards the current signal to `target_pid`.

  Optional `signal_type`, `payload` and `source` override the outgoing envelope.
  Returns the supplied state and an `Emit` directive; delivery happens later.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    pid = input.arguments[:target_pid]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    original = input.context.aikido.signal
    final_type = resolve_type(type, original)
    final_payload = resolve_payload(payload, original)
    final_source = resolve_source(source, original)

    out_signal =
      case original do
        %Aikido.Signal{} ->
          %{original | type: final_type, data: final_payload, source: final_source}

        _ ->
          %Aikido.Signal{type: final_type, data: final_payload, source: final_source}
      end

    directive = Aikido.Directives.emit_to_pid(out_signal, pid)
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
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
