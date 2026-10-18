defmodule AikidoTest.PluginTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.PluginTestAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :plugin_test_action, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.PluginTestAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.PluginTestAnotherAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value =
      case Map.fetch(input.arguments, :value) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:value]
      end

    Aikido.ActionResult.new(state: %{value: value}, directives: [])
  end
end

defmodule AikidoTest.PluginTestAnotherAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :plugin_test_another_action, Aikido.ActionResult do
      argument :state, :term
      argument :value, :integer, default: 0
      run {AikidoTest.PluginTestAnotherAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.NotAnActionModule do
  @moduledoc false
  def some_function do
    :ok
  end
end

defmodule AikidoTest.TestActions.BasicAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value =
      case Map.fetch(input.arguments, :value) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:value]
      end

    Aikido.ActionResult.new(state: %{value: value}, directives: [])
  end
end

defmodule AikidoTest.TestActions.BasicAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :basic_action, Aikido.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      description "A basic action for testing"
      run {AikidoTest.TestActions.BasicAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.NoSchema.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    runtime = input.context.aikido

    signal = %{
      runtime.signal
      | data: Map.merge(runtime.signal.data || %{}, Map.delete(input.arguments, :state))
    }

    case {signal, input.arguments.state, runtime[:action_opts] || %{}, runtime} do
      {%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx} ->
        Aikido.ActionResult.new(state: %{result: value + 2}, directives: [])

      {_signal, _slice, _opts, _ctx} ->
        Aikido.ActionResult.new(state: %{result: "No params"}, directives: [])
    end
  end
end

defmodule AikidoTest.TestActions.NoSchema do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :no_schema, Aikido.ActionResult do
      argument :state, :term
      description "Action with no schema"
      run {AikidoTest.TestActions.NoSchema.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.Add.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value =
      case Map.fetch(input.arguments, :value) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:value]
      end

    amount =
      case Map.fetch(input.arguments, :amount) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:amount]
      end

    Aikido.ActionResult.new(state: %{value: value + amount}, directives: [])
  end
end

defmodule AikidoTest.TestActions.Add do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :add, Aikido.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      argument :amount, :integer, default: 1
      description "Adds amount to value"
      run {AikidoTest.TestActions.Add.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.EmitAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal = %{type: "test.emitted", data: %{value: 42}}
    Aikido.ActionResult.new(state: %{emitted: true}, directives: [Aikido.Directives.emit(signal)])
  end
end

defmodule AikidoTest.TestActions.EmitAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :emit_action, Aikido.ActionResult do
      argument :state, :term
      description "Action that returns an emit effect"
      run {AikidoTest.TestActions.EmitAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.MultiEffectAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    effects = [
      Aikido.Directives.emit(%{type: "event.1"}),
      Aikido.Directives.schedule(1000, :check)
    ]

    Aikido.ActionResult.new(state: %{triggered: true}, directives: effects)
  end
end

defmodule AikidoTest.TestActions.MultiEffectAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :multi_effect_action, Aikido.ActionResult do
      argument :state, :term
      description "Action that returns multiple effects"
      run {AikidoTest.TestActions.MultiEffectAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.MultiSliceAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(
      state: %Aikido.Agent.SliceUpdate{
        slices: %{domain: %{primary: "result"}, audit: %{last_event: :touched}}
      },
      directives: []
    )
  end
end

defmodule AikidoTest.TestActions.MultiSliceAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :multi_slice_action, Aikido.ActionResult do
      argument :state, :term
      description "Action that returns a SliceUpdate writing two slices in one turn"
      run {AikidoTest.TestActions.MultiSliceAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.IncrementAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    amount =
      case Map.fetch(input.arguments, :amount) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:amount]
      end

    slice = input.arguments.state

    slice =
      if is_map(slice) do
        slice
      else
        %{}
      end

    count = Map.get(slice, :counter, 0)
    Aikido.ActionResult.new(state: Map.put(slice, :counter, count + amount), directives: [])
  end
end

defmodule AikidoTest.TestActions.IncrementAction do
  @moduledoc "Action that increments the :counter state field"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :increment, Aikido.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run {AikidoTest.TestActions.IncrementAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.DecrementAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    amount =
      case Map.fetch(input.arguments, :amount) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:amount]
      end

    slice = input.arguments.state

    slice =
      if is_map(slice) do
        slice
      else
        %{}
      end

    count = Map.get(slice, :counter, 0)
    Aikido.ActionResult.new(state: Map.put(slice, :counter, count - amount), directives: [])
  end
end

defmodule AikidoTest.TestActions.DecrementAction do
  @moduledoc "Action that decrements the :counter state field"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :decrement, Aikido.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run {AikidoTest.TestActions.DecrementAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.RecordAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params =
      Map.merge(input.context.aikido.signal.data || %{}, Map.delete(input.arguments, :state))

    slice = input.arguments.state
    messages = Map.get(slice, :messages, [])
    message = Map.get(params, :message, params)
    Aikido.ActionResult.new(state: %{messages: messages ++ [message]}, directives: [])
  end
end

defmodule AikidoTest.TestActions.RecordAction do
  @moduledoc "Action that appends params to the :messages state field"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :record, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.TestActions.RecordAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.SlowAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay =
      case Map.fetch(input.arguments, :delay_ms) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:delay_ms]
      end

    Process.sleep(delay)
    Aikido.ActionResult.new(state: %{processed: true, delay: delay}, directives: [])
  end
end

defmodule AikidoTest.TestActions.SlowAction do
  @moduledoc "Action that sleeps for a configurable delay"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :slow, Aikido.ActionResult do
      argument :state, :term
      argument :delay_ms, :integer, default: 100
      run {AikidoTest.TestActions.SlowAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.TestActions.FailingAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason =
      case Map.fetch(input.arguments, :reason) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:reason]
      end

    {:error, reason}
  end
end

defmodule AikidoTest.TestActions.FailingAction do
  @moduledoc "Action that always fails with a configurable error message"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :failing, Aikido.ActionResult do
      argument :state, :term
      argument :reason, :string, default: "intentional failure"
      run {AikidoTest.TestActions.FailingAction.Implementation, action: :run}
    end
  end
end
