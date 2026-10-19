defmodule Aikido.AgentServer.Signal.LifecycleStarting do
  @moduledoc """
  Emitted by the AgentServer at the start of `init/1`, after the agent
  struct is constructed via the native `:initialize` Ash action and before any plugin
  children, subscriptions, schedules, or routers are wired up.

  Routed through the middleware chain. `Aikido.Middlewares.Persister`, when
  configured, observes this signal and synchronously thaws the agent from
  storage, replacing `ctx.agent` before delegating downstream.

  Middleware that observes `lifecycle.starting` MUST NOT depend on
  post-init state — there are no children, no router, and no
  subscriptions yet at this stage.
  """

  use Jido.Signal,
    type: "aikido.agent.lifecycle.starting",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: []
end
