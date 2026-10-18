defmodule Aikido.Dsl.Instance.Host do
  @moduledoc """
  Internal Spark.Dsl wrapper that imports the `instance do … end` section
  macro from `Aikido.Dsl.Instance` into modules that `use Aikido`.

  Users do not call this directly — `use Aikido, otp_app: …` expands to
  `use Aikido.Dsl.Instance.Host` plus a synthesised `instance` block built
  from the kwargs. `Aikido.Dsl.Instance.Transformers.GenerateAccessors` then
  emits the runtime instance surface (`__otp_app__/0` /
  `__aikido_storage__/0` / `__default_slices__/0`, `child_spec/1`,
  `start_link/1`, `start_agent/2`, debug helpers, …).

  Lives separate from `Aikido` itself so `use Spark.Dsl`'s generated
  `init/1` callback doesn't collide with `use Supervisor`'s `init/1` on
  the `Aikido` module.
  """

  use Spark.Dsl, default_extensions: [extensions: [Aikido.Dsl.Instance]]
end
