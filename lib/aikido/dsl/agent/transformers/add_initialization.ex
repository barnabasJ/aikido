defmodule Aikido.Dsl.Agent.Transformers.AddInitialization do
  @moduledoc false
  use Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    {:ok, id} =
      Ash.Resource.Builder.build_action_argument(:id, :string,
        allow_nil?: false,
        default: &Aikido.Util.generate_id/0
      )

    {:ok, state} =
      Ash.Resource.Builder.build_action_argument(:state, :map, allow_nil?: false, default: %{})

    with {:ok, dsl} <-
           Ash.Resource.Builder.add_new_action(dsl, :action, :initialize,
             returns: Aikido.Agent,
             arguments: [id, state],
             run:
               {Aikido.Agent.Initialize,
                path: Spark.Dsl.Extension.get_opt(dsl, [:agent], :path),
                slices: Spark.Dsl.Transformer.get_persisted(dsl, :slice_instances, [])}
           ),
         {:ok, dsl} <-
           Ash.Resource.Builder.add_new_interface(dsl, :initialize, action: :initialize) do
      dsl =
        if Ash.Resource.Info.domain(dsl) || Ash.Resource.Info.code_interface_domain(dsl) do
          dsl
        else
          interfaces = Ash.Resource.Info.interfaces(dsl)

          Spark.Dsl.Transformer.eval(
            dsl,
            [],
            quote do
              require Ash.CodeInterface

              Ash.CodeInterface.define_interface(
                nil,
                __MODULE__,
                unquote(Macro.escape(interfaces))
              )
            end
          )
        end

      {:ok, dsl}
    end
  end
end
