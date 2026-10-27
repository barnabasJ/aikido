defmodule AikidoTest.TestActions.Actions.PreserveState do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: Aikido.Types.ActionResult.new(state: input.arguments.state)
end

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

    Aikido.Types.ActionResult.new(state: %{input.arguments.state | value: value}, directives: [])
  end
end

defmodule AikidoTest.TestActions.Actions.ResolveOptionalValue do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = Map.get(input.arguments, :value)
    result = if is_nil(value), do: "No params", else: value + 2
    Aikido.Types.ActionResult.new(state: %{input.arguments.state | result: result})
  end
end

defmodule AikidoTest.TestActions.Actions.AddValue do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    value = input.arguments.value

    amount = input.arguments.amount

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | value: value + amount},
      directives: []
    )
  end
end

defmodule AikidoTest.TestActions.Actions.EmitTestSignal do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal = %{type: "test.emitted", data: %{value: 42}}

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | emitted: true},
      directives: [Aikido.Directives.emit(signal)]
    )
  end
end

defmodule AikidoTest.TestActions.Actions.EmitAndSchedule do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    effects = [
      Aikido.Directives.emit(%{type: "event.1"}),
      Aikido.Directives.schedule(1000, :check)
    ]

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | triggered: true},
      directives: effects
    )
  end
end

defmodule AikidoTest.TestActions.Actions.RecordWorkflowResult do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{input.arguments.state | primary: "result"})
  end
end

defmodule AikidoTest.TestActions.Actions.RecordAuditEvent do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    if input.arguments.reject? do
      {:error, :audit_rejected}
    else
      Aikido.Types.ActionResult.new(state: %{input.arguments.state | last_event: :touched})
    end
  end
end

defmodule AikidoTest.TestActions.Actions.IncrementCounter do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    amount = input.arguments.amount

    slice = input.arguments.state

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

    Aikido.Types.ActionResult.new(
      state: %{slice | messages: messages ++ [message]},
      directives: []
    )
  end
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
