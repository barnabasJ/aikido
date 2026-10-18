defmodule Aikido.AI.TestActions do
  @moduledoc false
end

(
  defmodule Aikido.AI.TestActions.TestAdd.Implementation do
    @moduledoc false
    use Ash.Resource.Actions.Implementation
    @impl true
    def run(input, _opts, _context) do
      a =
        case Map.fetch(input.arguments, :a) do
          {:ok, value} -> value
          :error -> input.context.aikido.signal.data[:a]
        end

      b =
        case Map.fetch(input.arguments, :b) do
          {:ok, value} -> value
          :error -> input.context.aikido.signal.data[:b]
        end

      Aikido.ActionResult.new(state: %{result: a + b}, directives: [])
    end
  end

  defmodule Aikido.AI.TestActions.TestAdd do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "test_add", description: "Adds two integers and returns their sum."}}
    actions do
      action :run, Aikido.ActionResult do
        argument :state, :term
        argument :a, :integer, description: "First addend", allow_nil?: false
        argument :b, :integer, description: "Second addend", allow_nil?: false
        description "Adds two integers and returns their sum."
        run Aikido.AI.TestActions.TestAdd.Implementation
      end
    end
  end
)

(
  defmodule Aikido.AI.TestActions.TestMultiply.Implementation do
    @moduledoc false
    use Ash.Resource.Actions.Implementation
    @impl true
    def run(input, _opts, _context) do
      a =
        case Map.fetch(input.arguments, :a) do
          {:ok, value} -> value
          :error -> input.context.aikido.signal.data[:a]
        end

      b =
        case Map.fetch(input.arguments, :b) do
          {:ok, value} -> value
          :error -> input.context.aikido.signal.data[:b]
        end

      Aikido.ActionResult.new(state: %{result: a * b}, directives: [])
    end
  end

  defmodule Aikido.AI.TestActions.TestMultiply do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{
                name: "test_multiply",
                description: "Multiplies two integers and returns their product."
              }}
    actions do
      action :run, Aikido.ActionResult do
        argument :state, :term
        argument :a, :integer, description: "First factor", allow_nil?: false
        argument :b, :integer, description: "Second factor", allow_nil?: false
        description "Multiplies two integers and returns their product."
        run Aikido.AI.TestActions.TestMultiply.Implementation
      end
    end
  end
)

(
  defmodule Aikido.AI.TestActions.TestEcho.Implementation do
    @moduledoc false
    use Ash.Resource.Actions.Implementation
    @impl true
    def run(input, _opts, _context) do
      message =
        case Map.fetch(input.arguments, :message) do
          {:ok, value} -> value
          :error -> input.context.aikido.signal.data[:message]
        end

      Aikido.ActionResult.new(state: %{echo: message}, directives: [])
    end
  end

  defmodule Aikido.AI.TestActions.TestEcho do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "test_echo", description: "Echoes the input message back as the result."}}
    actions do
      action :run, Aikido.ActionResult do
        argument :state, :term
        argument :message, :string, description: "The message to echo", allow_nil?: false
        description "Echoes the input message back as the result."
        run Aikido.AI.TestActions.TestEcho.Implementation
      end
    end
  end
)

(
  defmodule Aikido.AI.TestActions.TestFails.Implementation do
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

  defmodule Aikido.AI.TestActions.TestFails do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{
                name: "test_fails",
                description: "Always returns an error — used to exercise tool-failure paths."
              }}
    actions do
      action :run, Aikido.ActionResult do
        argument :state, :term
        argument :reason, :string, description: "Failure reason", default: "test_failure"
        description "Always returns an error — used to exercise tool-failure paths."
        run Aikido.AI.TestActions.TestFails.Implementation
      end
    end
  end
)
