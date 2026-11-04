defmodule Aikido.RequesterCorrelationTest.Client do
  @moduledoc "Controlled provider for actual native Todo-gated requester runs."
  def generate_text(_model, messages, _options) do
    send(
      Process.whereis(Aikido.RequesterCorrelationTest.Observer),
      {:requester_model, self(), messages}
    )

    receive do
      {:respond, response} -> {:ok, response}
    end
  end
end

defmodule Aikido.RequesterCorrelationTest.Requester do
  use Ash.Resource,
    domain: Aikido.RequesterCorrelationTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "correlation_requester"
    instance Aikido.RequesterCorrelationTest.Instance
    persistence :temporary
    slice :todos, Aikido.Todo.Slice

    schema do
      attribute :actor_id, :string do
        description "The immutable requesting execution principal."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline:correlation"
    client Aikido.RequesterCorrelationTest.Client
    options %{completion: :todos, model_max_retries: 0}
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.RequesterCorrelationTest.Worker do
  use Ash.Resource,
    domain: Aikido.RequesterCorrelationTest.Domain,
    extensions: [Aikido.Agent.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "correlation_worker"
    instance Aikido.RequesterCorrelationTest.Instance
    persistence :temporary

    schema do
      attribute :actor_id, :string do
        description "The sibling's immutable execution principal."
        allow_nil? false
      end

      attribute :work_count, :integer do
        description "Number of actual native task deliveries received."
        default 0
        allow_nil? false
      end

      attribute :seen_actor, :string do
        description "The actual principal receiving the task."
      end

      attribute :pending_work, :map do
        description "Task correlation held until the application's explicit finish event."
      end
    end

    route Aikido.TeamMemberAdmissionTest.Work, Aikido.TeamMemberAdmissionTest.RunWork, name: :work

    route Aikido.TeamMemberAdmissionTest.Finish, Aikido.TeamMemberAdmissionTest.FinishWork,
      name: :finish
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.RequesterCorrelationTest.RejectStartup do
  @moduledoc "A real application's native initial topology rejection."
  use Aikido.Middleware
  @impl true
  def on_signal(signal, context, _options, next) do
    if signal.type == "aikido.ash.team.start" do
      {:error, context,
       Ash.Error.Action.InvalidArgument.exception(
         field: :topology,
         message: "The application rejected this worker's initial topology."
       )}
    else
      next.(signal, context)
    end
  end
end

defmodule Aikido.RequesterCorrelationTest.FailingWorker do
  use Ash.Resource,
    domain: Aikido.RequesterCorrelationTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "correlation_failing_worker"
    instance Aikido.RequesterCorrelationTest.Instance
    persistence :temporary
    middleware [Aikido.RequesterCorrelationTest.RejectStartup]

    schema do
      attribute :actor_id, :string do
        description "The native principal of the application-rejected activation."
        allow_nil? false
      end
    end
  end

  team do
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.RequesterCorrelationTest.Coordinator do
  use Ash.Resource,
    domain: Aikido.RequesterCorrelationTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "correlation_coordinator"
    instance Aikido.RequesterCorrelationTest.Instance
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "The coordinator's immutable application principal."
        allow_nil? false
      end
    end
  end

  team do
    worker :worker, Aikido.RequesterCorrelationTest.Worker
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end

    policy action(:assign_task) do
      authorize_if Aikido.Team.PolicyChecks.MemberDelegation
    end
  end
end

defmodule Aikido.RequesterCorrelationTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :coordinator, Aikido.RequesterCorrelationTest.Coordinator
    agent :requester, Aikido.RequesterCorrelationTest.Requester
    agent :worker, Aikido.RequesterCorrelationTest.Worker
    agent :failing_worker, Aikido.RequesterCorrelationTest.FailingWorker
  end
end
