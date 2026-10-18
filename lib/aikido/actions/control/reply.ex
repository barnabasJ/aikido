defmodule Aikido.Actions.Control.Reply do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    input = input.context.aikido.signal

    case extract_reply_to(input) do
      {:ok, pid} ->
        out = Jido.Signal.new!(type, payload, source: "/reply")
        directive = Aikido.Directives.emit_to_pid(out, pid)
        Aikido.ActionResult.new(state: %{replied_to: pid}, directives: [directive])

      :error ->
        Aikido.ActionResult.new(
          state: %{replied_to: nil, warning: "No reply_to found in signal"},
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
