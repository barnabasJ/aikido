defmodule Aikido.AiReact.Actions.Ask do
  @moduledoc "Starts a configured run, rejecting concurrent setup or model work."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{RunState, RunCaller}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- prepare_requested_run(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp prepare_requested_run(input) do
    input
    |> start_run()
    |> RunCaller.bind_run_caller(input)
    |> RunState.resolve_run_outcome(input)
    |> Aikido.AiReact.HookQueue.queue_event_hooks_if_changed(
      input,
      :run_started,
      Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
    )
  end

  defp start_run(input) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    if slice.status in [:setup, :running] do
      {:error, :busy}
    else
      RunState.begin_run(data, slice)
    end
  end
end
