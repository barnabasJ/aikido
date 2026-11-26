defmodule Aikido.ReactQuintTest do
  use ExUnit.Case, async: false

  use AshQuint.Case,
    model: :react_stream,
    adapter: AikidoTest.ReactQuint.Adapter,
    sensitivity: true
end
