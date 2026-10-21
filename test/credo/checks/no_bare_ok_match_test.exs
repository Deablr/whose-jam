Code.require_file("credo/checks/no_bare_ok_match.ex")

defmodule WhoseJam.Credo.Checks.NoBareOkMatchTest do
  use Credo.Test.Case

  alias WhoseJam.Credo.Checks.NoBareOkMatch

  defp check(source), do: source |> to_source_file() |> run_check(NoBareOkMatch)

  test "a bare :ok match is flagged at its line" do
    """
    defmodule Sample do
      def run do
        :ok = Game.start(1)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end

  test "bare {:ok, _} matches of any arity are flagged" do
    """
    defmodule Sample do
      def run do
        {:ok, auth} = connect()
        {:ok, a, b} = connect()
      end
    end
    """
    |> check()
    |> assert_issues(2)
  end

  test "matching on an error or another shape is fine" do
    """
    defmodule Sample do
      def run do
        {:error, _} = connect()
        %{a: 1} = connect()
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "an ok-tuple alias in a function head is not an assertion" do
    """
    defmodule Sample do
      def run({:ok, _} = result), do: result
      defp step({:ok, _} = result) when is_tuple(result), do: result
    end
    """
    |> check()
    |> refute_issues()
  end

  test "ok-tuple aliases in case, fn and with patterns are not assertions" do
    """
    defmodule Sample do
      def run(x) do
        case x do
          {:ok, _} = r -> r
        end

        Enum.map(x, fn {:ok, _} = r -> r end)

        with {:ok, _} = r <- x, do: r
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "a bare match inside a clause body is still flagged" do
    """
    defmodule Sample do
      def run(x) do
        case x do
          _ ->
            :ok = Game.start(1)
        end
      end
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end
end
