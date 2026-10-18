defmodule Aikido.AI.TestActions do
  @moduledoc false
end

# Fixture action modules used by `Aikido.AI.*` tests. Compiled in `:test`
# only via `elixirc_paths(:test)`.
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

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp reduce(%Jido.Signal{data: %{a: a, b: b}}, _slice, _opts, _ctx) do
    {:ok, %{result: a + b}, []}
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

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp reduce(%Jido.Signal{data: %{a: a, b: b}}, _slice, _opts, _ctx) do
    {:ok, %{result: a * b}, []}
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

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp reduce(%Jido.Signal{data: %{message: message}}, _slice, _opts, _ctx) do
    {:ok, %{echo: message}, []}
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

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp reduce(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
    {:error, reason}
  end
end
