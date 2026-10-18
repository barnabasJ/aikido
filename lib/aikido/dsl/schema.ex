defmodule Aikido.Dsl.Schema do
  @moduledoc false

  def attribute_section(name \\ :schema),
    do: %{Enum.find(Ash.Resource.Dsl.sections(), &(&1.name == :attributes)) | name: name}
end
