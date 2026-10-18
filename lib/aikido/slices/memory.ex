defmodule Aikido.Slices.Memory do
  @moduledoc "Memory slice — owns the `:memory` key in agent state, mounted as a\n`%Aikido.Slices.Memory.State{}` value with named map / list spaces.\n\n## State shape\n\nBound to `Aikido.Slices.Memory.State.schema/0`. The slice starts as `nil` (lazy-init);\nthe first inbound `aikido.memory.*` signal materializes a fresh\n`%Aikido.Slices.Memory.State{}` via the relevant action.\n\n## Routes\n\nEach `aikido.memory.*` signal type maps to a single action under\n`Aikido.Slices.Memory.Actions.*`:\n\n    # ensure / put / update / delete\n    route \"aikido.memory.ensure\",            Actions.Ensure\n    route \"aikido.memory.put_space\",         Actions.PutSpace\n    route \"aikido.memory.update_space\",      Actions.UpdateSpace\n    route \"aikido.memory.ensure_space\",      Actions.EnsureSpace\n    route \"aikido.memory.delete_space\",      Actions.DeleteSpace\n\n    # map space ops\n    route \"aikido.memory.put_in_space\",      Actions.PutInSpace\n    route \"aikido.memory.delete_from_space\", Actions.DeleteFromSpace\n\n    # list space ops\n    route \"aikido.memory.append_to_space\",   Actions.AppendToSpace\n\n## Default slice\n\nThis slice is automatically included as a default slice for all agents\nunless explicitly disabled:\n\n    use Aikido.Agent, default_slices: %{memory: false}\n\n    agent do\n      name \"minimal\"\n    end\n\n## Persistence\n\nThis bare-minimum default slice keeps memory in-process only and does not\nexternalize on checkpoint. If you need a persistence transform, implement\nyour own slice that declares `@behaviour Aikido.Persist.Transform` and\noverride `default_slices: %{memory: MyApp.MyMemorySlice}`.\n"
  alias Aikido.Slices.Memory.State
  use Aikido.Slice

  @persist {:aikido_slice_schema, State}

  slice do
    name "memory"
    description "Memory state for agent cognition — named map / list spaces."

  end

  signal_routes do
    route "aikido.memory.ensure", {Aikido.Slices.Memory.Actions, :ensure}
    route "aikido.memory.put_space", {Aikido.Slices.Memory.Actions, :put_space}
    route "aikido.memory.update_space", {Aikido.Slices.Memory.Actions, :update_space}
    route "aikido.memory.ensure_space", {Aikido.Slices.Memory.Actions, :ensure_space}
    route "aikido.memory.delete_space", {Aikido.Slices.Memory.Actions, :delete_space}
    route "aikido.memory.put_in_space", {Aikido.Slices.Memory.Actions, :put_in_space}
    route "aikido.memory.delete_from_space", {Aikido.Slices.Memory.Actions, :delete_from_space}
    route "aikido.memory.append_to_space", {Aikido.Slices.Memory.Actions, :append_to_space}
  end

  capabilities do
    capability :memory
  end

  @memory_section %Spark.Dsl.Section{
    name: :memory,
    describe: "Configuration block contributed by Aikido.Slices.Memory.",
    schema: []
  }
  use Spark.Dsl.Extension,
    sections: [@memory_section],
    transformers: [Aikido.Slices.Memory.Transformers.RegisterContribution]
end
