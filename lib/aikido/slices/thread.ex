defmodule Aikido.Slices.Thread do
  @moduledoc "Thread slice — owns the `:thread` key in agent state, mounted as a\n`%Aikido.Slices.Thread.State{}` append-only conversation log.\n\n## State shape\n\nBound to `Aikido.Slices.Thread.State.schema/0`. The slice starts as `nil` (lazy-init);\nthe first inbound `aikido.thread.*` signal materializes a fresh\n`%Aikido.Slices.Thread.State{}` via the relevant action.\n\n## Routes\n\n    route \"aikido.thread.ensure\", Actions.Ensure\n    route \"aikido.thread.append\", Actions.Append\n    route \"aikido.thread.clear\",  Actions.Clear\n\n## Persistence\n\nThis slice implements `Aikido.Persist.Transform` to externalize the thread\nto its small pointer (`%{id, rev}`) on checkpoint. `reinstate/1` is a\npassthrough — actual rehydration happens via the existing\n`Aikido.Persist.thaw/3` path.\n\n## Default slice\n\nThis slice is automatically included as a default slice for all agents\nunless explicitly disabled:\n\n    use Aikido.Agent, default_slices: %{thread: false}\n\n    agent do\n      name \"minimal\"\n    end\n"
  alias Aikido.Slices.Thread.State
  use Aikido.Slice

  @persist {:aikido_slice_schema, State}

  slice do
    name "thread"
    description "Append-only conversation history thread for the agent."

  end

  signal_routes do
    route "aikido.thread.ensure", {Aikido.Slices.Thread.Actions, :ensure}
    route "aikido.thread.append", {Aikido.Slices.Thread.Actions, :append}
    route "aikido.thread.clear", {Aikido.Slices.Thread.Actions, :clear}
  end

  capabilities do
    capability :thread
  end

  @thread_section %Spark.Dsl.Section{
    name: :thread,
    describe: "Configuration block contributed by Aikido.Slices.Thread.",
    schema: []
  }
  use Spark.Dsl.Extension,
    sections: [@thread_section],
    transformers: [Aikido.Slices.Thread.Transformers.RegisterContribution]

  @behaviour Aikido.Persist.Transform
  @impl Aikido.Persist.Transform
  def externalize(%State{id: id, rev: rev}) do
    %{id: id, rev: rev}
  end

  def externalize(nil) do
    nil
  end

  def externalize(other) do
    other
  end

  @impl Aikido.Persist.Transform
  def reinstate(value) do
    value
  end
end
