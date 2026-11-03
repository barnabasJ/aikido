defmodule Aikido.Thread.Consumer.Signals.Drain do
  @moduledoc "Catch up every known live source, then pause journal demand."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.drain"
  end
end
