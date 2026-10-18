defmodule Aikido.AI.TestActions do
  @moduledoc false
  # Fixture action modules used by `Aikido.AI.*` tests. Compiled in `:test`
  # only via `elixirc_paths(:test)`.
end

defmodule Aikido.AI.TestActions.TestAdd do
  @moduledoc false
  use Aikido.Action

  action do
    name "test_add"
    description "Adds two integers and returns their sum."

    schema do
      attribute :a, :integer, description: "First addend", allow_nil?: false
      attribute :b, :integer, description: "Second addend", allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{a: a, b: b}}, _slice, _opts, _ctx) do
    {:ok, %{result: a + b}, []}
  end
end

defmodule Aikido.AI.TestActions.TestMultiply do
  @moduledoc false
  use Aikido.Action

  action do
    name "test_multiply"
    description "Multiplies two integers and returns their product."

    schema do
      attribute :a, :integer, description: "First factor", allow_nil?: false
      attribute :b, :integer, description: "Second factor", allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{a: a, b: b}}, _slice, _opts, _ctx) do
    {:ok, %{result: a * b}, []}
  end
end

defmodule Aikido.AI.TestActions.TestEcho do
  @moduledoc false
  use Aikido.Action

  action do
    name "test_echo"
    description "Echoes the input message back as the result."

    schema do
      attribute :message, :string, description: "The message to echo", allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{message: message}}, _slice, _opts, _ctx) do
    {:ok, %{echo: message}, []}
  end
end

defmodule Aikido.AI.TestActions.TestFails do
  @moduledoc false
  use Aikido.Action

  action do
    name "test_fails"
    description "Always returns an error — used to exercise tool-failure paths."

    schema do
      attribute :reason, :string, description: "Failure reason", default: "test_failure"
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
    {:error, reason}
  end
end
