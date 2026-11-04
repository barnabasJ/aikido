defmodule Aikido.Team.Types.CoordinationTaskStatus do
  @moduledoc "Lifecycle status exposed in the finite Team coordination view."
  use Ash.Type.Enum, values: [:pending, :dispatched, :completed, :failed]
end
