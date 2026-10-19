defmodule Aikido.AI.TestActions.TestAdd.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    a = input.arguments.a

    b = input.arguments.b

    {:ok, %{result: a + b}}
  end
end

defmodule Aikido.AI.TestActions.TestAdd do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.AI.TestToolDomain,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false

  actions do
    action :test_add, :map do
      argument :a, :integer, description: "First addend", allow_nil?: false
      argument :b, :integer, description: "Second addend", allow_nil?: false
      description "Adds two integers and returns their sum."
      run Aikido.AI.TestActions.TestAdd.Implementation
    end
  end
end

defmodule Aikido.AI.TestActions.TestMultiply.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    a = input.arguments.a

    b = input.arguments.b

    {:ok, %{result: a * b}}
  end
end

defmodule Aikido.AI.TestActions.TestMultiply do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.AI.TestToolDomain,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false

  actions do
    action :test_multiply, :map do
      argument :a, :integer, description: "First factor", allow_nil?: false
      argument :b, :integer, description: "Second factor", allow_nil?: false
      description "Multiplies two integers and returns their product."
      run Aikido.AI.TestActions.TestMultiply.Implementation
    end
  end
end

defmodule Aikido.AI.TestActions.TestEcho.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    message = input.arguments.message

    {:ok, %{echo: message}}
  end
end

defmodule Aikido.AI.TestActions.TestEcho do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.AI.TestToolDomain,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false

  actions do
    action :test_echo, :map do
      argument :message, :string, description: "The message to echo", allow_nil?: false
      description "Echoes the input message back as the result."
      run Aikido.AI.TestActions.TestEcho.Implementation
    end
  end
end

defmodule Aikido.AI.TestActions.TestFails.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments.reason

    {:error, Ash.Error.Action.InvalidArgument.exception(field: :reason, message: reason)}
  end
end

defmodule Aikido.AI.TestActions.TestFails do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.AI.TestToolDomain,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false

  actions do
    action :test_fails, :map do
      argument :reason, :string, description: "Failure reason", default: "test_failure"
      description "Always returns an error — used to exercise tool-failure paths."
      run Aikido.AI.TestActions.TestFails.Implementation
    end
  end
end
