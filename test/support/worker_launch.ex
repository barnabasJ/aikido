defmodule Aikido.WorkerLaunchTest.Client do
  def generate_text(model, _messages, opts) do
    if observer = opts[:observer], do: send(observer, {:worker_model, model})

    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant("done", tool_calls: []),
       finish_reason: :stop
     }}
  end
end

defmodule Aikido.WorkerLaunchTest.Worker do
  use Ash.Resource,
    domain: Aikido.WorkerLaunchTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "worker_launch"
    instance Aikido.WorkerLaunchTest.Instance
  end

  ai do
    client Aikido.WorkerLaunchTest.Client
  end
end

defmodule Aikido.WorkerLaunchTest.Team do
  use Ash.Resource,
    domain: Aikido.WorkerLaunchTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "worker_launch_team"
    instance Aikido.WorkerLaunchTest.Instance
  end

  team do
    member :worker, Aikido.WorkerLaunchTest.Worker, activation: :lazy
  end
end

defmodule Aikido.WorkerLaunchTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :launch, Aikido.WorkerLaunchTest.Team
    agent :worker, Aikido.WorkerLaunchTest.Worker
  end
end
