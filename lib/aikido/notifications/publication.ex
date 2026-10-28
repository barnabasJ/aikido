defmodule Aikido.Notifications.Publication do
  @moduledoc "A named publication of explicitly projected agent and slice data."

  defstruct [:name, :topic, __identifier__: nil, __spark_metadata__: nil]

  @doc false
  def schema do
    [
      name: [
        type: :atom,
        required: true,
        doc: "Publication name used by subscribers and its generated signal module."
      ],
      topic: [
        type: {:custom, Ash.Notifier.PubSub.Publication, :topic, []},
        required: true,
        doc: "Native Ash PubSub topic template, including any resource attribute bindings."
      ]
    ]
  end
end
