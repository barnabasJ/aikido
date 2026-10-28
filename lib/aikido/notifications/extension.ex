defmodule Aikido.Notifications.Extension do
  @moduledoc """
  Agent publication and subscription declarations backed by native Ash PubSub.

  Only explicit `notification_data` calculations contribute payload data.
  Subscription topics route messages; applications must resolve receiving scope
  and authorize access to their transport and topics independently.
  """

  @publication %Spark.Dsl.Entity{
    name: :publish,
    target: Aikido.Notifications.Publication,
    args: [:name],
    identifier: :name,
    schema: Aikido.Notifications.Publication.schema()
  }
  @subscription %Spark.Dsl.Entity{
    name: :subscribe,
    target: Aikido.Notifications.Subscription,
    args: [:resource, :publication],
    no_depend_modules: [:resource],
    schema: Aikido.Notifications.Subscription.schema()
  }
  @notifications %Spark.Dsl.Section{
    name: :notifications,
    entities: [@publication, @subscription],
    no_depend_modules: [:pubsub],
    schema: [
      pubsub: [
        type: :module,
        doc: "Endpoint or PubSub module used by this resource's publications."
      ],
      pubsub_name: [type: :atom, doc: "Optional named PubSub passed to the transport module."],
      scope: [
        type: :mfa,
        doc: "Application MFA resolving receiving scope from the current immutable agent."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@notifications],
    transformers: [Aikido.Notifications.Extension.Transformers.Build],
    persisters: [Ash.Notifier.PubSub.Persisters.SetCalcReturns],
    verifiers: [
      Aikido.Notifications.Extension.Verifiers.Validate,
      Ash.Notifier.PubSub.Verifiers.VerifyActionNames,
      Ash.Notifier.PubSub.Verifiers.VerifyCalcTransforms
    ]
end
