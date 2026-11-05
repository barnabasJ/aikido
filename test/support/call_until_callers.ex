defmodule AikidoTest.AgentServer.CallUntilCallersTest.Write do
  use Aikido.Signal

  signal do
    type "waiter.write"

    schema do
      attribute :value, :integer do
        description "Value adopted through the generated write command."
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.AgentServer.CallUntilCallersTest.WriteValue do
  use Ash.Resource.Actions.Implementation

  @impl Ash.Resource.Actions.Implementation
  @spec run(input :: Ash.ActionInput.t(), options :: keyword(), context :: map()) ::
          Aikido.Types.ActionResult.t()
  def run(input, _options, _context) do
    Aikido.Types.ActionResult.new(changes: %{value: input.arguments.value})
  end
end

defmodule AikidoTest.AgentServer.CallUntilCallersTest.CallerAllowed do
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  @spec describe(options :: keyword()) :: String.t()
  def describe(_options), do: "the current process descends from the request owner"

  @impl Ash.Policy.SimpleCheck
  @spec match?(actor :: term(), context :: map(), options :: keyword()) :: boolean()
  def match?(%{owner: owner}, _context, _options) when is_pid(owner) do
    owner in [self() | Process.get(:"$callers", [])]
  end

  def match?(_actor, _context, _options), do: false
end

defmodule AikidoTest.AgentServer.CallUntilCallersTest.Agent do
  use Aikido.Agent,
    domain: AikidoTest.AgentServer.CallUntilCallersTest.Domain,
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "waiter_subject"
    instance AikidoTest.AgentServer.CallUntilCallersTest.Instance
    persistence :temporary

    schema do
      attribute :value, :integer do
        description "Current value set by the real routed write action."
        default 0
        allow_nil? false
      end
    end

    route AikidoTest.AgentServer.CallUntilCallersTest.Write,
          AikidoTest.AgentServer.CallUntilCallersTest.WriteValue,
          name: :write
  end

  policies do
    policy action(:inspect) do
      authorize_if AikidoTest.AgentServer.CallUntilCallersTest.CallerAllowed
    end

    policy always() do
      authorize_if always()
    end
  end
end

defmodule AikidoTest.AgentServer.CallUntilCallersTest.Domain do
  use Ash.Domain, otp_app: :aikido, extensions: [Aikido.Domain.Extension]

  agents do
    agent :subject, AikidoTest.AgentServer.CallUntilCallersTest.Agent
  end
end
