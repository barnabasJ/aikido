defmodule Aikido.Team.Types.WorkerLifecycle do
  @moduledoc "Whether a task's worker remains available or stops after its work is settled."
  use Ash.Type.Enum, values: [:keep, :stop]
end
