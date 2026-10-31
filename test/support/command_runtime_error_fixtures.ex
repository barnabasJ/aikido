defmodule Aikido.CommandRuntimeErrorTest.Counter do
  @moduledoc "Private native counter for typed command-runtime regression tests."

  use Ash.Resource,
    domain: Aikido.CommandRuntimeErrorTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "runtime_error_counter"
    instance Aikido.CommandRuntimeErrorTest.Instance

    schema do
      attribute :count, :integer do
        description "Counter state exposed by the generated inspect command."
        default 0
      end
    end
  end
end

defmodule Aikido.CommandRuntimeErrorTest.Protected do
  @moduledoc "Native fixture that requires an actor before agent initialization."

  use Ash.Resource,
    domain: Aikido.CommandRuntimeErrorTest.Domain,
    extensions: [Aikido.Agent.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "runtime_error_protected"
    instance Aikido.CommandRuntimeErrorTest.Instance
  end

  policies do
    policy action([:start, :initialize, :__aikido_initialize_state__]) do
      authorize_if actor_present()
    end
  end
end

defmodule Aikido.CommandRuntimeErrorTest.Domain do
  @moduledoc "Test-only generated interfaces for command-runtime regression fixtures."

  use Ash.Domain, otp_app: :aikido, extensions: [Aikido.Domain.Extension]

  agents do
    agent :counter, Aikido.CommandRuntimeErrorTest.Counter
    agent :protected, Aikido.CommandRuntimeErrorTest.Protected
  end
end
