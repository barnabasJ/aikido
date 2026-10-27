defmodule Aikido.Slice do
  @moduledoc """
  A convenience host for an embedded Ash resource using `Aikido.Slice.Extension`.

  Native `Ash.Resource` options, including a domain and additional extensions,
  pass through to Ash. The embedded data layer is a default; slice verification
  still requires an embedded resource.
  """

  defmacro __using__(opts) do
    opts =
      opts
      |> Keyword.put_new(:data_layer, :embedded)
      |> Keyword.update(:extensions, [Aikido.Slice.Extension], &[Aikido.Slice.Extension | &1])

    quote do
      use Ash.Resource, unquote(opts)
    end
  end
end
