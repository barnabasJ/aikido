defmodule AikidoTest.TestActions.Noop.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.TestActions.BasicAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = input.arguments.value

    Aikido.Types.ActionResult.new(state: %{value: value}, directives: [])
  end
end

defmodule AikidoTest.TestActions.OptionalInput.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = Map.get(input.arguments, :value)
    result = if is_nil(value), do: "No params", else: value + 2
    Aikido.Types.ActionResult.new(state: %{result: result})
  end
end

defmodule AikidoTest.TestActions.Add.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = input.arguments.value

    amount = input.arguments.amount

    Aikido.Types.ActionResult.new(state: %{value: value + amount}, directives: [])
  end
end

defmodule AikidoTest.TestActions.EmitAction.Implementation do
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

defmodule AikidoTest.TestActions.MultiEffectAction.Implementation do
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

defmodule AikidoTest.TestActions.MultiSliceAction.Implementation do
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

defmodule AikidoTest.TestActions.IncrementAction.Implementation do
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

defmodule AikidoTest.TestActions.DecrementAction.Implementation do
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

defmodule AikidoTest.TestActions.RecordAction.Implementation do
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

defmodule AikidoTest.TestActions.SlowAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay = input.arguments.delay_ms

    AikidoTest.TestActions.SlowAction.Implementation.work(delay)
    Aikido.Types.ActionResult.new(state: %{processed: true, delay: delay}, directives: [])
  end

  # Deliberately expensive pure work: timeout tests must not model I/O in reducers.
  def work(units), do: work_steps(max(units, 1) * 100_000, 0)
  defp work_steps(0, sum), do: sum
  defp work_steps(left, sum), do: work_steps(left - 1, sum + left)
end

defmodule AikidoTest.TestActions.FailingAction.Implementation do
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
      run AikidoTest.TestActions.Noop.Implementation
    end

    action :basic_action, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      description "A basic action for testing"
      run AikidoTest.TestActions.BasicAction.Implementation
    end

    action :optional_input, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer
      description "Optional typed input"
      run AikidoTest.TestActions.OptionalInput.Implementation
    end

    action :add, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      argument :amount, :integer, default: 1
      description "Adds amount to value"
      run AikidoTest.TestActions.Add.Implementation
    end

    action :emit_action, Aikido.Types.ActionResult do
      argument :state, :term
      description "Action that returns an emit effect"
      run AikidoTest.TestActions.EmitAction.Implementation
    end

    action :multi_effect_action, Aikido.Types.ActionResult do
      argument :state, :term
      description "Action that returns multiple effects"
      run AikidoTest.TestActions.MultiEffectAction.Implementation
    end

    action :multi_slice_action, Aikido.Types.ActionResult do
      argument :state, :term
      description "Action that returns a SliceUpdate writing two slices in one turn"
      run AikidoTest.TestActions.MultiSliceAction.Implementation
    end

    action :increment, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run AikidoTest.TestActions.IncrementAction.Implementation
    end

    action :decrement, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run AikidoTest.TestActions.DecrementAction.Implementation
    end

    action :record, Aikido.Types.ActionResult do
      argument :state, :term
      argument :data, :map, default: %{}
      run AikidoTest.TestActions.RecordAction.Implementation
    end

    action :slow, Aikido.Types.ActionResult do
      argument :state, :term
      argument :delay_ms, :integer, default: 100
      run AikidoTest.TestActions.SlowAction.Implementation
    end

    action :failing, Aikido.Types.ActionResult do
      argument :state, :term
      argument :reason, :string, default: "intentional failure"
      run AikidoTest.TestActions.FailingAction.Implementation
    end
  end
end
