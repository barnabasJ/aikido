defmodule Aikido.Thread.Consumer.Types.SourceStatus do
  @moduledoc "Fixed native journal protocol states."
  use Ash.Type.Enum,
    values: [:ready, :watching, :gap, :rejected, :unavailable, :failed, :retrying]
end
