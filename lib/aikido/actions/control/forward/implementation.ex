defmodule Aikido.Actions.Control.Forward.Implementation do
  @moduledoc false
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
    out_signal = Jido.Signal.new!(final_type, final_payload, source: final_source)
    directive = Aikido.Directives.emit_to_pid(out_signal, pid)
    Aikido.ActionResult.new(state: %{forwarded_to: pid}, directives: [directive])
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

  defp resolve_payload(nil, %{data: data}) when is_map(data) do
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
