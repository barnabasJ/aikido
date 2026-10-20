defmodule Aikido.Dsl.Instance.Host do
  @moduledoc """
  Spark host for runtime instance configuration.

  `use Aikido` declares the `instance` section on this host. Configuration is
  read through `Aikido.Dsl.Instance.Info`. The host adds only the entry points
  needed to place a runtime instance in a supervision tree. Agents use their
  domain actions for lifecycle operations.

  This host is separate from `Aikido` so Spark's callbacks do not collide with
  the supervisor implementation.
  """

  use Spark.Dsl, default_extensions: [extensions: [Aikido.Dsl.Instance]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @doc false
      def child_spec(opts \\ []), do: Aikido.child_spec(Aikido.config(__MODULE__, opts))

      @doc false
      def start_link(opts \\ []), do: Aikido.start_link(Aikido.config(__MODULE__, opts))
    end
  end
end
