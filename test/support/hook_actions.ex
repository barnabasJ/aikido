defmodule AikidoTest.HookActions.Question do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    send(input.context.observer, {:question, self(), input.arguments})

    receive do
      {:answer, answer} -> {:ok, answer}
    after
      5_000 -> {:error, "Question timed out"}
    end
  end
end

defmodule AikidoTest.HookActions.TerminalGate do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    send(input.context.observer, {:hook_waiting, input.arguments.event, self()})

    receive do
      :release -> {:ok, %{}}
    after
      5_000 -> {:error, "Terminal gate timed out"}
    end
  end
end

defmodule AikidoTest.HookActions.DeliveryGate do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    send(input.context.observer, {:delivery_gate, self(), input.arguments.event})

    receive do
      {:release, decision} -> {:ok, decision}
    after
      10_000 -> {:error, "Delivery gate timed out"}
    end
  end
end

defmodule AikidoTest.HookActions.Resource do
  use Ash.Resource, domain: AikidoTest.HookActions.Domain

  actions do
    action :question, :map do
      argument :choices, {:array, :string}, allow_nil?: false
      run AikidoTest.HookActions.Question
    end

    action :terminal_gate, :map do
      argument :event, Aikido.AiReact.Hooks.Types.Event, allow_nil?: false
      run AikidoTest.HookActions.TerminalGate
    end

    action :delivery_gate, :map do
      argument :event, :map, allow_nil?: false
      run AikidoTest.HookActions.DeliveryGate
    end
  end
end

defmodule AikidoTest.HookActions.Domain do
  use Ash.Domain, extensions: [AshLua.Domain]

  resources do
    resource AikidoTest.HookActions.Resource
  end

  lua do
    namespace "interactions" do
      action :question, AikidoTest.HookActions.Resource, :question, labels: [:hook_interactions]

      action :terminal_gate, AikidoTest.HookActions.Resource, :terminal_gate,
        labels: [:hook_interactions]

      action :delivery_gate, AikidoTest.HookActions.Resource, :delivery_gate,
        labels: [:hook_interactions]
    end
  end
end
