defmodule Aikido.Actions.Control.Reply do
  @moduledoc """
  Pure reducer that replies to the PID in the current signal's `data.reply_to`.

  Uses `signal_type` and `payload` to return an `Emit` directive while preserving
  `state`. Returns no directives when the signal has no reply PID.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    signal = input.context.aikido.signal

    case extract_reply_to(signal) do
      {:ok, pid} ->
        out = %Aikido.Signal{id: nil, type: type, data: payload, source: "/reply"}
        directive = Aikido.Directives.emit_to_pid(out, pid)
        Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])

      :error ->
        Aikido.Types.ActionResult.new(
          state: input.arguments.state,
          directives: []
        )
    end
  end

  defp extract_reply_to(%{data: %{reply_to: pid}}) when is_pid(pid) do
    {:ok, pid}
  end

  defp extract_reply_to(_) do
    :error
  end
end
