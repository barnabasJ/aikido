defmodule Aikido.Ash.Domain do
  @moduledoc """
  Registers agent resources and generates Ash code interfaces on a domain.

      use Ash.Domain, extensions: [Aikido.Ash.Domain]

      agents do
        agent :counter, MyApp.Counter
      end

  Each action is exposed as `<name>_<action>` (and its bang variant), for
  example `counter_start/1`, `counter_list/0`, or `counter_increment/2`.
  Ash's normal actor, authorization, context, and tenant options remain available.
  """
  defmodule Entry do
    @moduledoc false
    defstruct [:name, :resource, __identifier__: nil, __spark_metadata__: nil]
  end

  @entry %Spark.Dsl.Entity{
    name: :agent,
    target: Entry,
    args: [:name, :resource],
    identifier: :name,
    schema: [name: [type: :atom, required: true], resource: [type: :module, required: true]]
  }
  @agents %Spark.Dsl.Section{name: :agents, entities: [@entry]}
  use Spark.Dsl.Extension,
    sections: [@agents],
    transformers: [Aikido.Ash.Domain.Transformers.Build],
    verifiers: [Aikido.Ash.Domain.Verifiers.Validate]
end
