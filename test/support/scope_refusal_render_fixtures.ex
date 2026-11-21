defmodule Aikido.DurableScopeRefusalRenderTest.Recorder do
  @moduledoc "Private native counter whose scope adapter is controlled per test."

  use Ash.Resource,
    domain: Aikido.DurableScopeRefusalRenderTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "scope_refusal_recorder"
    instance Aikido.DurableScopeRefusalRenderTest.Instance

    schema do
      attribute :count, :integer do
        description "Counter state."
        default 0
      end
    end
  end
end

defmodule Aikido.DurableScopeRefusalRenderTest.Domain do
  @moduledoc "Test-only generated interfaces for the scope refusal render fixtures."

  use Ash.Domain, otp_app: :aikido, extensions: [Aikido.Domain.Extension]

  agents do
    agent :recorder, Aikido.DurableScopeRefusalRenderTest.Recorder
  end
end

defmodule Aikido.DurableScopeRefusalRenderTest.Denial do
  @moduledoc "Application-owned constrained public facts for a denied operation."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        subject: [type: :string, constraints: [max_length: 128, length_count: :bytes]],
        permissions: [
          type: {:array, :string},
          constraints: [max_length: 8, items: [max_length: 128, length_count: :bytes]]
        ]
      ]
    ]
end

defmodule Aikido.DurableScopeRefusalRenderTest.Authority do
  @moduledoc """
  Scope adapter whose `prepare/3` denies with caller-configured vars, so tests
  drive the real native start sanitization and rendered refusal message.
  """
  @behaviour Aikido.Durable.ScopeAdapter

  alias Aikido.Durable.ScopeAdapter.Error, as: ScopeRefusal

  @prepare_key {__MODULE__, :prepare}

  @doc "Configure the vars the next prepare denial carries."
  def deny(vars, denial_type \\ nil),
    do: :persistent_term.put(@prepare_key, {vars, denial_type})

  @impl true
  def prepare(_attributes, _options, _identity) do
    {vars, denial_type} = :persistent_term.get(@prepare_key, {[], nil})

    {:error,
     ScopeRefusal.exception(
       operation: :prepare,
       reason: :autonomous_worker_review_required,
       vars: vars,
       denial_type: denial_type
     )}
  end

  @impl true
  def restore(_credential, _saved, _identity), do: {:error, :scope_adapter_required}

  @impl true
  def checkpoint(_agent, _credential, _identity), do: {:error, :scope_adapter_required}
end
