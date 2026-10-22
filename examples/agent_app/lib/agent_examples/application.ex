defmodule AgentExamples.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [
        AgentExamples.Settings.Vault,
        AgentExamples.Settings.Repo,
        {Ecto.Migrator, repos: [AgentExamples.Settings.Repo], log: false},
        {Aikido, max_tasks: 20_000},
        {Phoenix.PubSub, name: AgentExamples.PubSub},
        {Task.Supervisor, name: AgentExamples.WebTasks},
        AgentExamples.Playground,
        AgentExamples.Quicksort.RunHistory,
        AgentExamplesWeb.Endpoint
      ],
      strategy: :one_for_one,
      name: AgentExamples.Supervisor
    )
  end
end
