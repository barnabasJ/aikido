defmodule Aikido.Ash.Transformers.Slice do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    declared = Transformer.get_entities(dsl, [:slice, :schema])
    existing = Ash.Resource.Info.attributes(dsl)
    names = Enum.map(declared ++ existing, & &1.name)

    if length(names) != length(Enum.uniq(names)) do
      raise Spark.Error.DslError,
        message: "Slice schema and resource attributes must have unique names",
        path: [:slice, :schema]
    end

    dsl = Enum.reduce(declared, dsl, &Transformer.add_entity(&2, [:attributes], &1))
    routes = Transformer.get_entities(dsl, [:slice])
    schedules = Transformer.get_entities(dsl, [:schedules])

    cond do
      !Ash.Resource.Info.embedded?(dsl) ->
        error("Aikido.Ash.Slice requires data_layer: :embedded")

      Enum.any?(routes ++ schedules, &invalid_action?(dsl, &1.action)) ->
        error(
          "Slice routes require generic Ash actions with a :state argument and Aikido.ActionResult return type"
        )

      true ->
        generate(dsl, routes, schedules)
    end
  end

  defp invalid_action?(dsl, name) do
    case Ash.Resource.Info.action(dsl, name) do
      %{type: :action, returns: Aikido.ActionResult, arguments: arguments} ->
        names = Enum.map(arguments, & &1.name)
        :state not in names

      _ ->
        true
    end
  end

  defp generate(dsl, routes, schedules) do
    resource = Transformer.get_persisted(dsl, :module)
    name = Transformer.get_option(dsl, [:slice], :name)

    scheduled_routes =
      schedules
      |> Enum.reject(fn entry -> Enum.any?(routes, &(&1.action == entry.action)) end)
      |> Enum.map(fn entry ->
        %Aikido.Ash.Slice.Route{
          type: "aikido.ash.schedule.#{name}.#{entry.action}",
          action: entry.action
        }
      end)

    # Action ownership comes from routes, including actions used only by cron.
    routing =
      Enum.map(routes ++ scheduled_routes, fn route ->
        target = {resource, route.action}

        quote do
          route unquote(route.type), unquote(Macro.escape(target))
        end
      end)

    subscriptions =
      Enum.map(Transformer.get_entities(dsl, [:subscriptions]), fn entry ->
        quote do
          subscription unquote(entry.sensor), unquote(Macro.escape(entry.config))
        end
      end)

    scheduled =
      Enum.map(schedules, fn entry ->
        target = {resource, entry.action}

        quote do
          schedule unquote(entry.cron), unquote(Macro.escape(target)),
            data: unquote(Macro.escape(entry.data))
        end
      end)

    block =
      quote do
        defmodule unquote(Module.concat(resource, AikidoSlice)) do
          import Aikido.Ash.Slice, only: []
          use Aikido.Slice

          @doc false
          def __aikido_resource__, do: unquote(resource)

          @persist {:aikido_slice_schema, unquote(resource)}

          slice do
            name unquote(name)
          end

          signal_routes do
            (unquote_splicing(routing))
          end

          subscriptions do
            (unquote_splicing(subscriptions))
          end

          schedules do
            (unquote_splicing(scheduled))
          end
        end
      end

    {:ok, Transformer.eval(dsl, [], block)}
  end

  defp error(message) do
    {:error, Spark.Error.DslError.exception(message: message, path: [:slice])}
  end
end
