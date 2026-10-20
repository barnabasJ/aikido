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
      case notification.resource do
        nil -> %{notification | resource: runtime.agent_module}
        _ -> notification
      end

    notification =
      case notification.actor do
        nil -> %{notification | actor: Aikido.Signal.get(signal, :actor)}
        _ -> notification
      end

    notification =
      case notification.data do
        %Aikido.Signal{} = data ->
          data =
            data
            |> Aikido.Directive.materialize_signal()
            |> Aikido.Signal.inherit(signal)

          %{notification | data: data}

        _ ->
          notification
      end

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        case Ash.Notifier.notify(notification) do
          [] -> :ok
          unsent -> Logger.warning("#{length(unsent)} Ash notifications remain unsent")
        end

        {:signals, []}
      end
    }

    case Aikido.Directives.AsyncTask.start(task, signal, runtime) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("Could not start notification: #{inspect(reason)}")
    end

    :ok
  end
end
