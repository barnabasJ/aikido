defmodule AikidoTest.AgentWait do
  @moduledoc """
  Subscribe-based wait helpers for agent state changes.

  Use these helpers when the wait condition is a predicate over agent state.

  Each helper:

  1. Registers a one-shot subscription before checking the current state.
  2. Reads the state once, returning immediately if the condition holds.
  3. Otherwise waits for the subscription notification. The selector returns
     `:skip` until a matching signal produces the required state.
  4. Removes the subscription when the wait finishes or times out.

  Selectors run in the agent process after the outermost middleware
  unwinds, so the predicate sees the fully processed state.
  """

  alias Aikido.AgentServer

  @default_timeout 500
  # `"**"` is the multi-segment wildcard — matches every signal type.
  # Single `"*"` only matches one segment, so it would miss multi-segment
  # types like `"cron.tick"` or `"aikido.agent.lifecycle.ready"`.
  @default_pattern "**"

  @doc """
  Wait for `value_fn.(state)` to return a non-`nil` value. Returns the
  value.

  ## Options

    * `:timeout` - ms to wait (default: #{@default_timeout})
    * `:pattern` - signal pattern to subscribe on (default: `"**"` — the
      multi-segment wildcard, matches every signal type). Use a tighter
      pattern (e.g. `"aikido.agent.child.started"`) when you know exactly
      which signal advances the predicate; tighter patterns avoid a
      selector run on every unrelated signal.

  ## Examples

      # Wait until counter reaches 5
      counter =
        AikidoTest.AgentWait.await_state_value(pid, fn s ->
          if s.agent.state.domain.counter >= 5, do: s.agent.state.domain.counter
        end)
      assert counter == 5

      # Wait until a child appears, narrow pattern
      child_pid =
        AikidoTest.AgentWait.await_state_value(
          pid,
          fn s -> Map.get(Aikido.Ownership.children(s), :worker) end,
          pattern: "aikido.agent.child.started"
        )
  """
  @spec await_state_value(GenServer.server(), (Aikido.AgentServer.State.t() -> any()), keyword()) ::
          any()
  def await_state_value(pid, value_fn, opts \\ []) when is_function(value_fn, 1) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    pattern = Keyword.get(opts, :pattern, @default_pattern)

    selector = fn state ->
      case value_fn.(state) do
        nil -> :skip
        value -> {:ok, value}
      end
    end

    {:ok, ref} = AgentServer.subscribe(pid, pattern, selector, once: true)

    try do
      case AgentServer.state(pid, &{:ok, value_fn.(&1)}) do
        {:ok, value} when not is_nil(value) ->
          value

        _ ->
          receive do
            {:aikido_subscription, ^ref, %{result: {:ok, value}}} -> value
          after
            timeout ->
              raise ExUnit.AssertionError,
                message:
                  "await_state_value/3 predicate not satisfied within #{timeout}ms (pattern=#{inspect(pattern)})"
          end
      end
    after
      AgentServer.unsubscribe(pid, ref)

      receive do
        {:aikido_subscription, ^ref, _result} -> :ok
      after
        0 -> :ok
      end
    end
  end
end
