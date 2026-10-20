defmodule Aikido.Signal.Definition do
  @moduledoc false
  use Spark.Dsl, default_extensions: [extensions: [Aikido.Signal.Dsl]]

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @doc "Construct this typed signal and materialize its runtime metadata."
      def new(data, opts \\ []), do: Aikido.Signal.from_definition(__MODULE__, data, opts)

      @doc "Construct this typed signal, raising on invalid data."
      def new!(data, opts \\ []), do: new(data, opts) |> Ash.Helpers.unwrap_or_raise!()
    end
  end
end
