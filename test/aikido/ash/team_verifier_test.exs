defmodule AikidoTest.AshTeamVerifierTest.ForeignAgent do
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "foreign"
    instance AikidoTest.ForeignInstance
  end
end

defmodule AikidoTest.AshTeamVerifierTest do
  use ExUnit.Case, async: false

  test "valid declarations pass the registered verifier" do
    assert "" = compile_team("member :lead, AikidoTest.AshFixtures.Counter")
  end

  test "requires the agent extension" do
    errors = compile_team("", agent?: false)
    assert_team_error(errors, "requires the Aikido.Agent.Extension extension")
  end

  test "rejects duplicate member declarations before they disappear into a map" do
    errors =
      compile_team("""
      member :lead, AikidoTest.AshFixtures.Counter
      member :lead, AikidoTest.AshFixtures.Counter
      """)

    assert_team_error(errors, "Got duplicate")
  end

  test "rejects duplicate worker templates" do
    errors =
      compile_team("""
      worker :helper, AikidoTest.AshFixtures.Counter
      worker :helper, AikidoTest.AshFixtures.Counter
      """)

    assert_team_error(errors, "Got duplicate")
  end

  test "rejects members declared in both the graph and member entities" do
    errors =
      compile_team("""
      topology %{lead: %{resource: AikidoTest.AshFixtures.Counter}}
      member :lead, AikidoTest.AshFixtures.Counter
      """)

    assert_team_error(errors, "Duplicate topology member")
  end

  test "checks worker resource instances after compilation" do
    errors = compile_team("worker :helper, AikidoTest.AshTeamVerifierTest.ForeignAgent")
    assert_team_error(errors, "All team members must use the team's Aikido instance")
  end

  test "validates graph dependencies through the verifier" do
    errors =
      compile_team("member :lead, AikidoTest.AshFixtures.Counter, depends_on: [:missing]")

    assert_team_error(errors, "invalid_member")
  end

  defp compile_team(body, opts \\ []) do
    module = Module.concat(__MODULE__, "Team#{System.unique_integer([:positive])}")
    agent? = Keyword.get(opts, :agent?, true)

    extensions =
      if agent?,
        do: [Aikido.Agent.Extension, Aikido.Team.Extension],
        else: [Aikido.Team.Extension]

    agent =
      if agent? do
        """
        agent do
          name "verified_team"
          instance AikidoTest.AshFixtures.Instance
        end
        """
      else
        ""
      end

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: #{inspect(extensions)}

        #{agent}
        team do
          #{body}
        end
      end
      """)
    end)
  end

  defp assert_team_error(output, text) do
    assert output =~ "team"
    assert output =~ text
  end
end
