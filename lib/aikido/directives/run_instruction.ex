defmodule Aikido.Directives.RunInstruction do
  @moduledoc """
  Execute a `%Aikido.Instruction{}` at runtime and route the result via
  a signal. The directive does the I/O only — running the instruction
  and emitting a result signal. The state mutation that consumes the
  result happens in an action bound to `result_signal_type` via the
  agent's `signal_routes/1`.

  The framework does **not** call `cmd/2` directly from the directive
  body anymore — that crossed the directive/action boundary. Wire a
  handler:

      # in the agent
      def signal_routes(_ctx) do
        [{"myapp.async.result", MyApp.HandleAsyncResult}]
      end

      # the directive
      Directives.run_instruction(instruction,
        result_signal_type: "myapp.async.result"
      )

  ## Fields

  - `instruction` - The `%Aikido.Instruction{}` to execute
  - `result_signal_type` - Type of the signal emitted with the result
    payload. The agent's `signal_routes` should bind this type to a
    handler action that sets the appropriate slice fields.
  - `meta` - Optional metadata echoed in the result payload

  The result-signal payload shape:

      %{
        status: :ok | :error,
        result: any(),     # only when :ok
        reason: any(),     # only when :error
        effects: [...],    # action's directives, only when :ok
        instruction: %Aikido.Instruction{},
        meta: map()
      }
  """

  use Aikido.Directive

  typed_struct do
    field :instruction, :term, allow_nil?: false, description: "%Aikido.Instruction{} to execute"

    field :result_signal_type, :term,
      allow_nil?: false,
      description: "Signal type used to route the execution result. Bind via signal_routes."

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Optional metadata for result payload"
  end

  @type t :: %__MODULE__{}

  @doc """
  Pure I/O directive: runs the instruction and emits a result signal of
  type `result_signal_type`. The directive does not call `cmd/2`
  directly — the agent's `signal_routes` binds `result_signal_type` to
  a handler action that performs the slice update via its return value.
  The handler runs on the next mailbox turn through the normal pipeline.
  """

  alias Aikido.AgentServer
  alias Aikido.Observe.Config, as: ObserveConfig

  @impl true
  def exec(
        %{instruction: instruction, result_signal_type: signal_type, meta: meta},
        _input_signal,
        state
      ) do
    enriched_instruction = %{
      instruction
      | context: Map.put(instruction.context || %{}, :state, state.agent.state)
    }

    execution_payload =
      enriched_instruction
      |> then(fn instruction ->
        exec_opts = ObserveConfig.action_exec_opts(state.aikido, instruction.opts)
        Aikido.Exec.run(%{instruction | opts: exec_opts})
      end)
      |> normalize_result_payload()
      |> Map.put(:instruction, instruction)
      |> Map.put(:meta, meta || %{})

    result_signal =
      Jido.Signal.new!(signal_type, execution_payload, source: "/agent/#{state.id}")

    _ = AgentServer.cast(self(), result_signal)
    :ok
  end

  defp normalize_result_payload({:ok, result, effects}) do
    %{
      status: :ok,
      result: result,
      effects: List.wrap(effects)
    }
  end

  defp normalize_result_payload({:error, reason}) do
    %{
      status: :error,
      reason: reason,
      effects: []
    }
  end
end
