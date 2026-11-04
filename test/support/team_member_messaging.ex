defmodule Aikido.TeamMemberMessagingTest.Authority do
  @moduledoc "Authenticates ordinary members and one explicitly anonymous application worker."
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    if identity.agent_module == Aikido.TeamMemberMessagingTest.AnonymousWorker do
      AikidoTest.DurableScopeAuthority.prepare(attributes, [], identity)
    else
      Aikido.TeamMemberAdmissionTest.Authority.prepare(attributes, options, identity)
    end
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.TeamMemberMessagingTest.Message do
  use Aikido.Signal

  signal do
    type "test.member.message"

    schema do
      attribute :text, :string do
        description "Application message delivered to a receiving agent."
        allow_nil? false
      end

      attribute :grant, :string do
        description "Application-owned payload permission checked before delivery."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.TeamMemberMessagingTest.RecordMessage do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    Aikido.Types.ActionResult.new(
      changes: %{
        text: input.arguments.text,
        seen_actor: get_in(input.context, [:aikido, :actor, :id]),
        seen_tenant: input.context.aikido[:tenant],
        messages_received: input.arguments.state.messages_received + 1
      }
    )
  end
end

defmodule Aikido.TeamMemberMessagingTest.ObserveMessage do
  @moduledoc "Observes real delivery context without persisting runtime process identifiers."
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _options, next) do
    if signal.type in ["test.member.message", "ai.react.deliver"] do
      if observer = Process.whereis(Aikido.TeamMemberMessagingTest.Observer) do
        send(observer, {:message_observed, self(), signal.type, context})
      end
    end

    next.(signal, context)
  end
end

defmodule Aikido.TeamMemberMessagingTest.PayloadGrant do
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "the application permits this message payload"

  @impl true
  def match?(_actor, %{subject: input}, _options) do
    data = Map.get(input.arguments, :data, input.arguments)
    payload = data[:payload] || %{}

    payload[:grant] == "allowed" &&
      Enum.all?(Map.keys(payload), &(&1 in [:text, :grant, :request_id, :metadata]))
  end
end

defmodule Aikido.TeamMemberMessagingTest.MessageFields do
  @moduledoc "Common application schema and routes for real messaging agents."
  defmacro __using__(_options) do
    quote do
      agent do
        persistence :temporary
        middleware [Aikido.TeamMemberMessagingTest.ObserveMessage]

        schema do
          attribute :actor_id, :string do
            description "Application principal bound by the native activation authority."
            allow_nil? false
          end

          attribute :text, :string do
            description "The last application message received through the native pipeline."
          end

          attribute :seen_actor, :string do
            description "The actual receiving principal used by the application action."
          end

          attribute :seen_tenant, :term do
            description "The actual receiving tenant used by the application action."
          end

          attribute :messages_received, :integer do
            description "Count of accepted application messages."
            default 0
            allow_nil? false
          end
        end

        route Aikido.TeamMemberMessagingTest.Message,
              Aikido.TeamMemberMessagingTest.RecordMessage,
              name: :message
      end

      policies do
        policy always() do
          authorize_if actor_attribute_equals(:allowed, true)
        end
      end
    end
  end
end

defmodule Aikido.TeamMemberMessagingTest.Worker do
  use Ash.Resource,
    domain: Aikido.TeamMemberMessagingTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension]

  use Aikido.TeamMemberMessagingTest.MessageFields

  agent do
    name "messaging_worker"
    instance Aikido.TeamMemberMessagingTest.Instance
  end
end

defmodule Aikido.TeamMemberMessagingTest.Coordinator do
  use Ash.Resource,
    domain: Aikido.TeamMemberMessagingTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  use Aikido.TeamMemberMessagingTest.MessageFields

  agent do
    name "messaging_coordinator"
    instance Aikido.TeamMemberMessagingTest.Instance
  end

  team do
    worker :worker, Aikido.TeamMemberMessagingTest.Worker
  end

  policies do
    policy action(:send) do
      forbid_unless Aikido.TeamMemberMessagingTest.PayloadGrant

      authorize_if {Aikido.Team.PolicyChecks.MemberMessaging,
                    types: ["test.member.message", "ai.react.deliver"]}
    end
  end
end

defmodule Aikido.TeamMemberMessagingTest.AnonymousWorker do
  @moduledoc "An intentionally anonymous application agent, independent of its bound coordinator."
  use Ash.Resource,
    domain: Aikido.TeamMemberMessagingTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "messaging_anonymous_worker"
    instance Aikido.TeamMemberMessagingTest.Instance
    persistence :temporary
    middleware [Aikido.TeamMemberMessagingTest.ObserveMessage]

    schema do
      attribute :text, :string do
        description "The last accepted application message."
      end

      attribute :seen_actor, :string do
        description "The receiving principal, absent for this anonymous worker."
      end

      attribute :seen_tenant, :term do
        description "The receiving tenant, absent for this anonymous worker."
      end

      attribute :messages_received, :integer do
        description "Count of accepted application messages."
        default 0
        allow_nil? false
      end
    end

    route Aikido.TeamMemberMessagingTest.Message,
          Aikido.TeamMemberMessagingTest.RecordMessage,
          name: :message
  end
end

defmodule Aikido.TeamMemberMessagingTest.Client do
  @moduledoc "A controlled provider for real bound AI runs; no runtime handles enter saved configuration."
  def generate_text(model, messages, options) do
    send(
      Process.whereis(Aikido.TeamMemberMessagingTest.Observer),
      {:messaging_provider_called, self(), model, messages, options}
    )

    receive do
      {:provider_result, result} -> result
    end
  end
end

defmodule Aikido.TeamMemberMessagingTest.AiReceiver do
  use Ash.Resource,
    domain: Aikido.TeamMemberMessagingTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "messaging_ai_receiver"
    instance Aikido.TeamMemberMessagingTest.Instance
    persistence :temporary
    middleware [Aikido.TeamMemberMessagingTest.ObserveMessage]

    schema do
      attribute :actor_id, :string do
        description "Receiving AI principal authenticated by native activation."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline:messaging"
    client Aikido.TeamMemberMessagingTest.Client
    options %{model_max_retries: 0}
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.TeamMemberMessagingTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :coordinator, Aikido.TeamMemberMessagingTest.Coordinator
    agent :worker, Aikido.TeamMemberMessagingTest.Worker
    agent :anonymous_worker, Aikido.TeamMemberMessagingTest.AnonymousWorker
    agent :ai_receiver, Aikido.TeamMemberMessagingTest.AiReceiver
  end
end
