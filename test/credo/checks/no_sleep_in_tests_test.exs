Code.require_file("credo/checks/no_sleep_in_tests.ex")

defmodule WhoseJam.Credo.Checks.NoSleepInTestsTest do
  use Credo.Test.Case

  alias WhoseJam.Credo.Checks.NoSleepInTests

  defp check(source), do: source |> to_source_file() |> run_check(NoSleepInTests)

  test "Process.sleep is flagged at its line" do
    """
    defmodule SampleTest do
      use ExUnit.Case

      test "x" do
        Process.sleep(100)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end

  test ":timer.sleep is flagged, including in a pipe or capture" do
    """
    defmodule SampleTest do
      use ExUnit.Case

      test "x" do
        :timer.sleep(100)
        100 |> Process.sleep()
        Enum.each([1], &Process.sleep/1)
      end
    end
    """
    |> check()
    |> assert_issues(3)
  end

  test "waiting on messages and process state is fine" do
    """
    defmodule SampleTest do
      use ExUnit.Case

      test "x" do
        assert_receive {:done, _}, 500
        _ = :sys.get_state(self())
        Process.monitor(self())
      end
    end
    """
    |> check()
    |> refute_issues()
  end
end
