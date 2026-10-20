defmodule Aikido.Dsl.Agent.Verifiers.Composition do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    with :ok <- verify_sections(dsl) do
      middleware = Verifier.get_persisted(dsl, :middleware_list, [])

      Enum.reduce_while(middleware, :ok, fn {module, _opts}, :ok ->
        if Code.ensure_loaded?(module) && Spark.implements_behaviour?(module, Aikido.Middleware) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              message: "Middleware module #{inspect(module)} must implement Aikido.Middleware",
              path: [:agent, :middleware]
            )}}
        end
      end)
    end
  end

  defp verify_sections(dsl) do
    duplicates =
      dsl
      |> Verifier.get_persisted(:aikido_contributed_sections, %{})
      |> Enum.group_by(fn {_module, section} -> section end, fn {module, _section} -> module end)
      |> Enum.filter(fn {_section, modules} -> length(Enum.uniq(modules)) > 1 end)

    if duplicates == [] do
      :ok
    else
      message =
        Enum.map_join(duplicates, "; ", fn {section, modules} ->
          names = modules |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)
          "section #{inspect(section)} is contributed by multiple extensions: #{names}"
        end)

      {:error,
       Spark.Error.DslError.exception(message: "Section name collisions: " <> message, path: [])}
    end
  end
end
