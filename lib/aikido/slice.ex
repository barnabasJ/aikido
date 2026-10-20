defmodule Aikido.Slice do
  @moduledoc "A convenience host for an embedded Ash resource using `Aikido.Ash.Slice`."

  defmacro __using__(opts) do
    Keyword.validate!(opts, [])

    quote do
      use Ash.Resource,
        data_layer: :embedded,
        validate_domain_inclusion?: false,
        extensions: [Aikido.Ash.Slice]
    end
  end
end
