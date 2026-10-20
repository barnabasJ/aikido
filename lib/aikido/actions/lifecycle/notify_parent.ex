defmodule Aikido.Actions.Lifecycle.NotifyParent do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    ctx = input.context.aikido
    signal = struct!(Jido.Signal, id: nil, type: type, data: payload, source: source)

    directive =
      case Map.get(ctx, :parent) do
        %Aikido.AgentServer.ParentRef{pid: pid} when is_pid(pid) ->
          Aikido.Directives.emit_to_pid(signal, pid)

        _ ->
          nil
      end

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: List.wrap(directive)
    )
  end
end
