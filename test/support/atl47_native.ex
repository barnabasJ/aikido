defmodule AikidoTest.Atl47Native.Client do
  @behaviour Aikido.AiReact.Client

  @impl true
  def generate_text(_model, messages, options) do
    send(options[:observer], {:atl47_model, self(), options[:label] || :lead, messages, options})

    receive do
      {:response, response} -> response
    after
      15_000 -> {:error, :provider_fixture_timeout}
    end
  end
end

defmodule AikidoTest.Atl47Native.Verify do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, context) do
    send(input.arguments.metadata.observer, {:atl47_verifier_context, self(), input.context})

    send(
      input.arguments.metadata.observer,
      {:atl47_verify, self(), input.arguments, context.actor, context.tenant}
    )

    receive do
      {:verification, response} -> response
    after
      15_000 -> {:error, :verifier_fixture_timeout}
    end
  end
end

defmodule AikidoTest.Atl47Native.Verifier do
  use Ash.Resource, domain: AikidoTest.Atl47Native.Domain

  actions do
    action :verify_typed, Aikido.AiReact.TodoVerification do
      argument :answer, :term
      argument :todos, {:array, :term}
      argument :metadata, :map
      argument :data, :term
      run AikidoTest.Atl47Native.Verify
    end

    action :verify, :term do
      argument :answer, :term
      argument :todos, {:array, :term}
      argument :metadata, :map
      argument :data, :term
      run AikidoTest.Atl47Native.Verify
    end
  end
end

defmodule AikidoTest.Atl47Native.LegacyVerifier do
  use Ash.Resource, domain: AikidoTest.Atl47Native.Domain

  actions do
    action :verify, :boolean do
      argument :answer, :term
      argument :todos, {:array, :term}
      argument :metadata, :map
      run AikidoTest.Atl47Native.Verify
    end
  end
end

defmodule AikidoTest.Atl47Native.ActivationGate do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _options, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if Ash.Changeset.get_attribute(changeset, :hold_activation) do
        observer = Ash.Changeset.get_attribute(changeset, :activation_observer)
        send(observer, {:atl47_activation, self()})

        receive do
          :activate_worker -> :ok
        after
          15_000 -> raise "activation fixture timed out"
        end
      end

      changeset
    end)
  end
end

defmodule AikidoTest.Atl47Native.Worker do
  use Ash.Resource,
    domain: AikidoTest.Atl47Native.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "atl47_worker"
    instance AikidoTest.Atl47Native.Instance

    schema do
      attribute :hold_activation, :boolean do
        description "Hold the real initialization action while its assignment awaits activation."
        default false
        public? true
      end

      attribute :activation_observer, :term do
        description "Receives the external initialization fixture handshake."
        public? true
      end
    end
  end

  changes do
    change AikidoTest.Atl47Native.ActivationGate, on: [:create]
  end
end

defmodule AikidoTest.Atl47Native.Agent do
  use Ash.Resource,
    domain: AikidoTest.Atl47Native.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension, Aikido.Team.Extension]

  agent do
    name "atl47_owner"
    instance AikidoTest.Atl47Native.Instance
    slice :todos, Aikido.Todo.Slice
  end

  team do
    worker :worker, AikidoTest.Atl47Native.Worker, max_members: 4
  end
end

defmodule AikidoTest.Atl47Native.Domain do
  use Ash.Domain, otp_app: :aikido

  resources do
    resource AikidoTest.Atl47Native.Agent
    resource AikidoTest.Atl47Native.Worker
    resource AikidoTest.Atl47Native.Verifier
    resource AikidoTest.Atl47Native.LegacyVerifier
  end
end

defmodule AikidoTest.Atl47Native.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import AikidoTest.Atl47Native.Case
      alias Aikido.AI.Test.ResponseFixtures, as: Responses
      alias AikidoTest.Atl47Native
    end
  end

  setup do
    instance = AikidoTest.Atl47Native.Instance
    directory = Path.join(System.tmp_dir!(), "atl47-native-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.start_supervised!(
      {Aikido,
       name: instance,
       durable: [
         data_dir: directory,
         scope_adapter: AikidoTest.DurableScopeAuthority,
         durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
       ]}
    )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, scope: [actor: %{id: "atl47-owner"}, tenant: "atl47-org"], instance: instance}
  end

  def start_owner(context, extra_options \\ %{}, attributes \\ %{}) do
    options =
      Map.merge(
        %{
          completion: :todos,
          todo_continuation: :nudge_once,
          max_todo_continuations: 10,
          handoff: false
        },
        extra_options
      )

    attributes =
      Map.merge(
        %{
          id: Ash.UUIDv7.generate(),
          model: "offline",
          client: AikidoTest.Atl47Native.Client,
          llm_opts: [observer: self(), label: :lead],
          max_iterations: 20,
          tools: [],
          tool_options: [otp_app: :aikido],
          tool_context: %{context: %{observer: self()}},
          options: options
        },
        attributes
      )

    command!(AikidoTest.Atl47Native.Agent, :start, attributes, context.scope)
  end

  def command!(resource, action, arguments, scope) do
    resource |> Ash.ActionInput.for_action(action, arguments, scope) |> Ash.run_action!()
  end

  def owner_command!(context, reference, action, arguments),
    do:
      command!(
        AikidoTest.Atl47Native.Agent,
        action,
        Map.put(arguments, :agent, reference),
        context.scope
      )

  def require_work(context, reference, id \\ "work") do
    owner_command!(context, reference, :todo_add, %{
      id: id,
      text: "Provide evidence for #{id}",
      blocking?: true
    })
  end

  def ask_owner(context, reference, query \\ "finish the work", metadata \\ %{}) do
    request_id = Ash.UUIDv7.generate()
    metadata = Map.merge(%{observer: self()}, metadata)

    owner_command!(context, reference, :ask, %{
      query: query,
      request_id: request_id,
      metadata: metadata
    })

    request_id
  end

  def ai(reference), do: Aikido.AgentServer.state(reference.pid, &{:ok, &1.agent.state.ai})

  def await_ai(reference, predicate) do
    AikidoTest.AgentWait.await_state_value(
      reference.pid,
      fn runtime ->
        if predicate.(runtime.agent.state.ai), do: runtime.agent.state.ai
      end,
      timeout: 5_000
    )
  end

  def complete_work(context, reference, id \\ "work") do
    owner_command!(context, reference, :todo_complete, %{
      id: id,
      result: "Native recorded evidence"
    })
  end

  def text(messages),
    do:
      Enum.map_join(messages, "\n", fn message ->
        Enum.map_join(message.content, &(&1.text || ""))
      end)

  def respond(model, response), do: send(model, {:response, {:ok, response}})

  def verdict(verifier, response), do: send(verifier, {:verification, {:ok, response}})

  def verify_options, do: %{todo_verifier: {AikidoTest.Atl47Native.Verifier, :verify}}
end
