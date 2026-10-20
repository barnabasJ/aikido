defmodule AikidoTest.TestActions.Actions.ClearState do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.StoreValue do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = input.arguments.value

    Aikido.Types.ActionResult.new(state: %{value: value}, directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.ResolveOptionalValue do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = Map.get(input.arguments, :value)
    result = if is_nil(value), do: "No params", else: value + 2
    Aikido.Types.ActionResult.new(state: %{result: result})
  end
end

defmodule AikidoTest.TestActions.Actions.AddValue do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = input.arguments.value

    amount = input.arguments.amount

    Aikido.Types.ActionResult.new(state: %{value: value + amount}, directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.EmitTestSignal do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    signal = %{type: "test.emitted", data: %{value: 42}}

    Aikido.Types.ActionResult.new(
      state: %{emitted: true},
      directives: [Aikido.Directives.emit(signal)]
    )
  end
end

defmodule AikidoTest.TestActions.Actions.EmitAndSchedule do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    effects = [
      Aikido.Directives.emit(%{type: "event.1"}),
      Aikido.Directives.schedule(1000, :check)
    ]

    Aikido.Types.ActionResult.new(state: %{triggered: true}, directives: effects)
  end
end

defmodule AikidoTest.TestActions.Actions.UpdateDomainAndAudit do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %Aikido.Agent.SliceUpdate{
        slices: %{domain: %{primary: "result"}, audit: %{last_event: :touched}}
      },
      directives: []
    )
  end
end

defmodule AikidoTest.TestActions.Actions.IncrementCounter do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    amount = input.arguments.amount

    slice = input.arguments.state

    slice =
      if is_map(slice) do
        slice
      else
        %{}
      end

    count = Map.get(slice, :counter, 0)
    Aikido.Types.ActionResult.new(state: Map.put(slice, :counter, count + amount), directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.DecrementCounter do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    amount = input.arguments.amount

    slice = input.arguments.state

    slice =
      if is_map(slice) do
        slice
      else
        %{}
      end

    count = Map.get(slice, :counter, 0)
    Aikido.Types.ActionResult.new(state: Map.put(slice, :counter, count - amount), directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.RecordMessage do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = input.arguments.data

    slice = input.arguments.state
    messages = Map.get(slice, :messages, [])
    message = Map.get(params, :message, params)
    Aikido.Types.ActionResult.new(state: %{messages: messages ++ [message]}, directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.ComputeSlowResult do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay = input.arguments.delay_ms

    AikidoTest.TestActions.Actions.ComputeSlowResult.work(delay)
    Aikido.Types.ActionResult.new(state: %{processed: true, delay: delay}, directives: [])
  end

  # Deliberately expensive pure work: timeout tests must not model I/O in reducers.
  def work(units), do: work_steps(max(units, 1) * 100_000, 0)
  defp work_steps(0, sum), do: sum
  defp work_steps(left, sum), do: work_steps(left - 1, sum + left)
end

defmodule AikidoTest.TestActions.Actions.Fail do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments.reason

    {:error, reason}
  end
end

defmodule AikidoTest.TestActions do
  @moduledoc "Reusable native slice actions for runtime tests."
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "test_actions"
  end

  actions do
    action :noop, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.TestActions.Actions.ClearState
    end

    action :basic_action, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      description "A basic action for testing"
      run AikidoTest.TestActions.Actions.StoreValue
    end

    action :optional_input, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer
      description "Optional typed input"
      run AikidoTest.TestActions.Actions.ResolveOptionalValue
    end

    action :add, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      argument :amount, :integer, default: 1
      description "Adds amount to value"
      run AikidoTest.TestActions.Actions.AddValue
    end

    action :emit_action, Aikido.Types.ActionResult do
      argument :state, :term
      description "Action that returns an emit effect"
      run AikidoTest.TestActions.Actions.EmitTestSignal
    end

    action :multi_effect_action, Aikido.Types.ActionResult do
      argument :state, :term
      description "Action that returns multiple effects"
      run AikidoTest.TestActions.Actions.EmitAndSchedule
    end

    action :multi_slice_action, Aikido.Types.ActionResult do
      argument :state, :term
      description "Action that returns a SliceUpdate writing two slices in one turn"
      run AikidoTest.TestActions.Actions.UpdateDomainAndAudit
    end

    action :increment, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run AikidoTest.TestActions.Actions.IncrementCounter
    end

    action :decrement, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run AikidoTest.TestActions.Actions.DecrementCounter
    end

    action :record, Aikido.Types.ActionResult do
      argument :state, :term
      argument :data, :map, default: %{}
      run AikidoTest.TestActions.Actions.RecordMessage
    end

    action :slow, Aikido.Types.ActionResult do
      argument :state, :term
      argument :delay_ms, :integer, default: 100
      run AikidoTest.TestActions.Actions.ComputeSlowResult
    end

    action :failing, Aikido.Types.ActionResult do
      argument :state, :term
      argument :reason, :string, default: "intentional failure"
      run AikidoTest.TestActions.Actions.Fail
    end
  end
end
