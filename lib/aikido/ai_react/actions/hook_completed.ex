defmodule Aikido.AiReact.Actions.HookCompleted do
  @moduledoc "Applies correlated hook decisions and resumes serialized synchronous continuations."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks}

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> apply_hook_result(Map.delete(input.arguments, :state))
  end

  @doc false
  def apply_hook_result(state, data) do
    data = Map.put(data, :result, data[:result] || {:error, data[:reason] || "hook task failed"})
    pending = Map.get(state, :hooks_pending, %{})

    cond do
      state.request_id != data.request_id ->
        Aikido.Types.ActionResult.new(state: state)

      data.mode == :async ->
        state =
          case data.result do
            {:error, reason} -> record_hook_error(state, data.name, reason)
            _ -> state
          end

        Aikido.Types.ActionResult.new(state: state)

      state.status not in [:setup, :running] || not Map.has_key?(pending, data.token) ->
        Aikido.Types.ActionResult.new(state: state)

      true ->
        {continuation, pending} = Map.pop!(pending, data.token)
        state = Map.put(state, :hooks_pending, pending)

        case data.result do
          {:ok, %Hooks.Decision{decision: :continue, context: context}} ->
            state =
              if context,
                do: Hooks.queue_hook_text_for_next_model_request(state, data.name, context),
                else: state

            Hooks.release_queued_steps(state, continuation.queue, continuation.status, [])

          {:ok, %Hooks.Decision{decision: :deny, message: message}} ->
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
      |> Aikido.AiReact.Run.clear_tools_and_handoff()

    Aikido.Types.ActionResult.new(state: state)
  end
end
