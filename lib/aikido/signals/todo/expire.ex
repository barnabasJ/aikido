defmodule Aikido.Signals.Todo.Expire do
  @moduledoc "Typed payload for `aikido.todo.expire`."
  use Aikido.Signal

  signal do
    type "aikido.todo.expire"

    schema do
      attribute :id, :string, allow_nil?: false

      attribute :revision, :integer, allow_nil?: false
    end
  end
end
