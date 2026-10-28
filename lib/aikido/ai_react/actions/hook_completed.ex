defmodule Aikido.AiReact.Actions.HookCompleted do
  @moduledoc "Applies correlated hook decisions and resumes serialized synchronous continuations."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.HookQueue

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_hook_completion(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp process_hook_completion(input) do
    input.arguments.state
    |> apply_hook_result(Map.delete(input.arguments, :state))
  end

  @doc false
  def apply_hook_result(state, data) do
    data = Map.put(data, :result, data[:result] || {:error, data[:reason] || "hook task failed"})
    pending = Map.get(state, :hooks_pending, %{})

    cond do
      state.request_id != data.request_id ->
        {:ok, state, []}

      data.mode == :async ->
        state =
          case data.result do
            {:error, reason} -> record_hook_error(state, data.name, reason)
            _ -> state
          end

        {:ok, state, []}

      state.status not in [:setup, :running] || not Map.has_key?(pending, data.token) ->
        {:ok, state, []}

      true ->
        {continuation, pending} = Map.pop!(pending, data.token)
        state = Map.put(state, :hooks_pending, pending)

        case data.result do
          {:ok, %Aikido.AiReact.Hooks.Decision{decision: :continue, context: context}} ->
            state =
              if context,
                do: HookQueue.queue_hook_text_for_next_model_request(state, data.name, context),
                else: state

            HookQueue.release_queued_steps(state, continuation.queue, continuation.status, [])

          {:ok, %Aikido.AiReact.Hooks.Decision{decision: :deny, message: message}} ->
            fail_run_and_clear_hooks(state, {:hook_denied, data.name, message})

          {:error, reason} ->
            fail_run_and_clear_hooks(
              record_hook_error(state, data.name, reason),
              {:hook_failed, data.name, reason}
            )
        end
    end
  end

  defp record_hook_error(state, name, reason),
    do:
      Map.put(
        state,
        :hook_errors,
        Enum.take([%{name: name, reason: reason} | Map.get(state, :hook_errors, [])], 20)
      )

  defp fail_run_and_clear_hooks(state, reason) do
    state =
      state
      |> Map.put(:status, :failed)
      |> Map.put(:error, reason)
      |> Map.put(:hooks_pending, %{})
      |> Map.put(:hook_terminal, nil)
      |> Aikido.AiReact.RunState.clear_tools_and_handoff()

    {:ok, state, []}
  end
end
