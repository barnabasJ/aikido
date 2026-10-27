defmodule Aikido.AI.TestToolDomain do
  use Ash.Domain, otp_app: :aikido, extensions: [AshAi]

  resources do
    resource Aikido.AI.TestTools.Wait
    resource Aikido.AI.TestTools.Identity
    resource Aikido.AI.TestActions.TestAdd
    resource Aikido.AI.TestActions.TestMultiply
    resource Aikido.AI.TestActions.TestFails
  end

  tools do
    tool :test_wait, Aikido.AI.TestTools.Wait, :wait
    tool :test_identity, Aikido.AI.TestTools.Identity, :identity
    tool :test_add, Aikido.AI.TestActions.TestAdd, :test_add
    tool :test_multiply, Aikido.AI.TestActions.TestMultiply, :test_multiply
    tool :test_fails, Aikido.AI.TestActions.TestFails, :test_fails
  end
end
