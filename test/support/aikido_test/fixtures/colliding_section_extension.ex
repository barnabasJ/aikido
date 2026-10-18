defmodule AikidoTest.Fixtures.CollidingSectionExtension.Transformers.RegisterContribution do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def before?(Aikido.Dsl.Agent.Transformers.WalkExtensions) do
    true
  end

  def before?(_) do
    false
  end

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    contributed = Transformer.get_persisted(dsl_state, :aikido_contributed_sections, %{})

    {:ok,
     Transformer.persist(
       dsl_state,
       :aikido_contributed_sections,
       Map.put(contributed, AikidoTest.Fixtures.CollidingSectionExtension, :shared_section)
     )}
  end
end

defmodule AikidoTest.Fixtures.CollidingSectionExtension do
  @moduledoc """
  Test fixture: a slice that contributes the same `:shared_section` section name as
  `another contributed extension`. Mounting both on the same agent should be rejected at compile
  time by `Aikido.Dsl.Agent.Verifiers.NoSectionNameCollisions`.
  """

  use Aikido.Slice

  slice do
    name "colliding_section"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "fixture.colliding_section.noop", AikidoTest.PluginTestAction
  end

  capabilities do
    capability :colliding_section
  end

  @section %Spark.Dsl.Section{
    name: :shared_section,
    describe:
      "Test fixture section colliding with another contributed extension's `shared_section do … end`.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [
      AikidoTest.Fixtures.CollidingSectionExtension.Transformers.RegisterContribution
    ]
end

defmodule AikidoTest.Fixtures.OtherCollidingSectionExtension.Transformers.RegisterContribution do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def before?(Aikido.Dsl.Agent.Transformers.WalkExtensions) do
    true
  end

  def before?(_) do
    false
  end

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    contributed = Transformer.get_persisted(dsl_state, :aikido_contributed_sections, %{})

    {:ok,
     Transformer.persist(
       dsl_state,
       :aikido_contributed_sections,
       Map.put(contributed, AikidoTest.Fixtures.OtherCollidingSectionExtension, :shared_section)
     )}
  end
end

defmodule AikidoTest.Fixtures.OtherCollidingSectionExtension do
  @moduledoc """
  Test fixture: a slice that contributes the same `:shared_section` section name as
  `another contributed extension`. Mounting both on the same agent should be rejected at compile
  time by `Aikido.Dsl.Agent.Verifiers.NoSectionNameCollisions`.
  """

  use Aikido.Slice

  slice do
    name "other_colliding_section"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "fixture.other_colliding_section.noop", AikidoTest.PluginTestAction
  end

  capabilities do
    capability :other_colliding_section
  end

  @section %Spark.Dsl.Section{
    name: :shared_section,
    describe:
      "Test fixture section colliding with another contributed extension's `shared_section do … end`.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [
      AikidoTest.Fixtures.OtherCollidingSectionExtension.Transformers.RegisterContribution
    ]
end
