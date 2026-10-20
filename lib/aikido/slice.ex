defmodule Aikido.Slice do
  @moduledoc """
  A convenience host for an embedded Ash resource using `Aikido.Ash.Slice`.

  Native `Ash.Resource` options, including a domain and additional extensions,
  pass through to Ash. The embedded data layer is a default; slice verification
  still requires an embedded resource.
  """

  defmacro __using__(opts) do
    opts =
      opts
      |> Keyword.put_new(:data_layer, :embedded)
      |> Keyword.update(:extensions, [Aikido.Ash.Slice], &[Aikido.Ash.Slice | &1])

    quote do
      use Ash.Resource, unquote(opts)
    end
  end
end
