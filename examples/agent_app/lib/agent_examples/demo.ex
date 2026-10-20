defmodule AgentExamples.Demo do
  @moduledoc "Run with `mix demo`; all work is local and needs no API keys."
  alias AgentExamples.Agents

  def run do
    try do
      counter = Agents.counter_start!(%{id: "demo-counter"})
      counter = Agents.counter_add!(counter, %{amount: "3"})
      counter = Agents.counter_inspect!(counter)
      IO.inspect(counter.count, label: "Counter (Ash casts the string argument)")

      checklist = Agents.checklist_start!(%{id: "demo-checklist"})
      checklist = Agents.checklist_add!(checklist, %{item: "Read the examples"})
      checklist = Agents.checklist_complete!(checklist, %{item: "Read the examples"})
      checklist = Agents.checklist_inspect!(checklist)
      IO.inspect(Map.take(checklist, [:items, :completed]), label: "Checklist")

      notebook = Agents.notebook_start!(%{id: "demo-notebook", title: "Lab notes"})
      notebook = Agents.notebook_append!(notebook, %{text: "Slices are embedded Ash resources."})
      notebook = Agents.notebook_inspect!(notebook)
      IO.inspect(notebook.journal.entries, label: "Notebook journal")

      worker = Agents.worker_start!(%{id: "demo-worker"})

      worker_pid = worker.pid

      result =
        after_signal(worker_pid, "worker.completed", fn ->
          Agents.worker_run!(worker, %{text: "signals carry results"})
        end)

      IO.inspect(result.result, label: "Async result")

      team = Agents.team_start!(%{id: "demo-team"})
      team = Agents.team_inspect!(team)
      counter_pid = team.team.members.counter

      after_signal(counter_pid, "counter.add", fn ->
        Agents.team_send!(team, %{
          data: %{member: :counter, type: "counter.add", payload: %{amount: 5}}
        })
      end)

      {:ok, count} = Aikido.AgentServer.state(counter_pid, &{:ok, &1.agent.state.state.count})
      IO.inspect(count, label: "Team counter (started at 10)")

      records =
        Agents.counter_list!()
        |> Enum.filter(&(&1.id == "demo-counter"))

      IO.inspect(Enum.map(records, & &1.id), label: "Filtered live agents")
      :ok
    after
      # Stop the demo's root agents; stopping a team also stops its members.
      for resource <- [
            AgentExamples.Counter,
            AgentExamples.Checklist,
            AgentExamples.Notebook,
            AgentExamples.Worker,
            AgentExamples.Team
          ],
          record <- resource |> Ash.ActionInput.for_action(:list, %{}) |> Ash.run_action!(),
          record.id in [
            "demo-counter",
            "demo-checklist",
            "demo-notebook",
            "demo-worker",
            "demo-team"
          ] do
        resource
        |> Ash.ActionInput.for_action(:stop, %{agent: record})
        |> Ash.run_action!()
      end
    end
  end

  defp after_signal(pid, type, send) do
    {:ok, reference} =
      Aikido.AgentServer.subscribe(pid, type, &{:ok, &1.agent.state.state}, once: true)

    try do
      send.()

      receive do
        {:aikido_subscription, ^reference, %{result: {:ok, state}}} -> state
      after
        5_000 -> raise "Timed out waiting for #{type}"
      end
    after
      Aikido.AgentServer.unsubscribe(pid, reference)
    end
  end
end
