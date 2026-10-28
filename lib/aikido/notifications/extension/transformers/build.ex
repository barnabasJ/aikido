defmodule Aikido.Notifications.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Aikido.Notifications.{Info, Projection}

  @impl true
  def after?(Aikido.Agent.Extension.Transformers.ExpandRoutes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    case Info.publications(dsl) do
      [] ->
        {:ok, dsl}

      publications ->
        with :ok <- validate_native_configuration(dsl) do
          build_publications(dsl, publications)
        end
    end
  end

  defp validate_native_configuration(dsl) do
    if Spark.Dsl.Extension.get_opt(dsl, [:pub_sub], :module) ||
         Spark.Dsl.Extension.get_entities(dsl, [:pub_sub]) != [] do
      {:error,
       Spark.Error.DslError.exception(
         module: Transformer.get_persisted(dsl, :module),
         path: [:notifications],
         message:
           "Do not combine Aikido publications with native pub_sub configuration on the same resource; configure publishing through notifications"
       )}
    else
      :ok
    end
  end

  defp build_publications(dsl, publications) do
    resource = Transformer.get_persisted(dsl, :module)
    mounts = Transformer.get_persisted(dsl, :slice_instances, [])
    path = Transformer.get_option(dsl, [:agent], :path)
    projections = Projection.definitions(dsl, mounts, path)
    fields = Projection.fields(projections)
    modules = Enum.map(publications, &Info.signal(resource, &1.name))

    if length(modules) != length(Enum.uniq(modules)) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:notifications],
        message: "Publication names must generate distinct signal module names"
    end

    with {:ok, dsl} <-
           Ash.Resource.Builder.add_calculation(
             dsl,
             Info.projection(resource),
             :map,
             {Aikido.Notifications.Calculations.Project, projections: projections},
             constraints: [fields: fields, preserve_nil_values?: true],
             allow_nil?: false,
             public?: false
           ) do
      dsl =
        dsl
        |> Transformer.persist(:aikido_notification_projections, projections)
        |> configure_native_pubsub()

      Enum.reduce_while(publications, {:ok, dsl}, fn publication, {:ok, dsl} ->
        with {:ok, native} <- native_publication(resource, publication) do
          dsl =
            dsl
            |> Transformer.add_entity([:pub_sub], native, type: :append)
            |> define_signal(resource, publication, fields)

          {:cont, {:ok, dsl}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp configure_native_pubsub(dsl) do
    ordinary = Transformer.get_persisted(dsl, :notifiers, [])
    simple = Transformer.get_persisted(dsl, :simple_notifiers, [])
    simple = Enum.reject(simple, &(&1 == Ash.Notifier.PubSub))
    simple = if Ash.Notifier.PubSub in ordinary, do: simple, else: simple ++ [Ash.Notifier.PubSub]

    dsl
    |> Transformer.set_option(
      [:pub_sub],
      :module,
      Transformer.get_option(dsl, [:notifications], :pubsub)
    )
    |> Transformer.set_option(
      [:pub_sub],
      :name,
      Transformer.get_option(dsl, [:notifications], :pubsub_name)
    )
    |> Transformer.set_option([:pub_sub], :broadcast_type, :broadcast)
    |> Transformer.set_option([:pub_sub], :delimiter, ":")
    |> Transformer.set_option([:pub_sub], :prefix, "")
    |> Transformer.persist(:simple_notifiers, simple)
  end

  defp native_publication(resource, publication) do
    Transformer.build_entity(Ash.Notifier.PubSub, [:pub_sub], :publish,
      action: :__aikido_apply_state__,
      event: to_string(publication.name),
      topic: publication.topic,
      transform: Info.projection(resource)
    )
  end

  defp define_signal(dsl, resource, publication, fields) do
    module = Info.signal(resource, publication.name)
    type = "aikido.notification." <> inspect(resource) <> "." <> to_string(publication.name)

    if Code.ensure_loaded?(module) &&
         !(function_exported?(module, :__aikido_publication__, 0) &&
             module.__aikido_publication__() == {resource, publication.name}) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:notifications, publication.name],
        message: "Generated signal #{inspect(module)} conflicts with an existing module"
    end

    attributes =
      Enum.map(fields, fn {name, options} ->
        quote do
          attribute unquote(name), unquote(options[:type]) do
            description unquote("Explicit notification projection for #{name}.")
            allow_nil? unquote(options[:allow_nil?])
            constraints unquote(Macro.escape(options[:constraints]))
          end
        end
      end)

    body =
      quote do
        @moduledoc "Generated typed publication signal."
        use Aikido.Signal

        @doc false
        def __aikido_publication__, do: unquote(Macro.escape({resource, publication.name}))

        signal do
          type unquote(type)

          schema do
            (unquote_splicing(attributes))
          end
        end
      end

    Transformer.eval(
      dsl,
      [],
      quote do
        Module.create(unquote(module), unquote(Macro.escape(body)), Macro.Env.location(__ENV__))
      end
    )
  end
end
