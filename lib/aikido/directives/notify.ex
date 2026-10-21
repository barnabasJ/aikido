defmodule Aikido.Directives.Notify do
  @moduledoc """
  Publish a native Ash notification in supervised work after state is applied.

  Applications can supply any native notifier through `notification.for`, or
  configure notifiers on `notification.resource`. Notification data containing
  a signal descriptor is materialized and inherits the originating scope.
  Missing resource and actor fields use the owning agent resource and caller.
  Explicit notification fields take precedence.
  """
  use Aikido.Directive

  typed_struct do
    field :notification, :struct do
      description "Native Ash notification published in supervised work after state adoption."
      allow_nil? false
      constraints instance_of: Ash.Notifier.Notification
    end
  end

  require Logger

  @impl true
  def exec(%{notification: notification}, signal, runtime) do
    notification =
      notification
      |> default_resource(runtime.agent_module)
      |> default_actor(Aikido.Signal.get(signal, :actor))
      |> materialize_notification_signal(signal)

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        case Ash.Notifier.notify(notification) do
          [] -> :ok
          unsent -> Logger.warning("#{length(unsent)} Ash notifications remain unsent")
        end

        {:signals, []}
      end
    }

    task
    |> Aikido.Directives.AsyncTask.start(signal, runtime)
    |> report_start_result()

    :ok
  end

  defp default_resource(%{resource: nil} = notification, resource),
    do: %{notification | resource: resource}

  defp default_resource(notification, _resource), do: notification

  defp default_actor(%{actor: nil} = notification, actor), do: %{notification | actor: actor}
  defp default_actor(notification, _actor), do: notification

  defp materialize_notification_signal(%{data: %Aikido.Signal{} = data} = notification, signal) do
    data = data |> Aikido.Directive.materialize_signal() |> Aikido.Signal.inherit(signal)
    %{notification | data: data}
  end

  defp materialize_notification_signal(notification, _signal), do: notification

  defp report_start_result({:ok, _pid}), do: :ok

  defp report_start_result({:error, reason}),
    do: Logger.error("Could not start notification: #{inspect(reason)}")
end
