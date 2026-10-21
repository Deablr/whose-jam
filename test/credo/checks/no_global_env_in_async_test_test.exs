Code.require_file("credo/checks/no_global_env_in_async_test.ex")

defmodule WhoseJam.Credo.Checks.NoGlobalEnvInAsyncTestTest do
  use Credo.Test.Case

  alias WhoseJam.Credo.Checks.NoGlobalEnvInAsyncTest

  defp check(source), do: source |> to_source_file() |> run_check(NoGlobalEnvInAsyncTest)

  test "changing the app env in an async module is flagged at its line" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: true

      test "x" do
        Application.put_env(:app, :key, 1)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end

  test "every kind of global write is flagged" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: true

      test "x" do
        Application.delete_env(:app, :key)
        Application.put_all_env(app: [key: 1])
        System.put_env("A", "1")
        System.delete_env("A")
      end
    end
    """
    |> check()
    |> assert_issues(4)
  end

  test "the same writes are fine in a non-async module" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: false

      test "x" do
        Application.put_env(:app, :key, 1)
        System.put_env("A", "1")
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "a module without an async option is not async" do
    """
    defmodule SampleTest do
      use ExUnit.Case

      test "x", do: Application.put_env(:app, :key, 1)
    end
    """
    |> check()
    |> refute_issues()
  end

  test "reading the env is fine in an async module" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: true

      test "x", do: Application.get_env(:app, :key)
    end
    """
    |> check()
    |> refute_issues()
  end

  test "each module is judged on its own async flag" do
    """
    defmodule AsyncTest do
      use ExUnit.Case, async: true
      test "x", do: :ok
    end

    defmodule SerialTest do
      use ExUnit.Case, async: false
      test "x", do: Application.put_env(:app, :key, 1)
    end
    """
    |> check()
    |> refute_issues()
  end

  test "a write in the async module is still flagged next to a serial one" do
    """
    defmodule SerialTest do
      use ExUnit.Case, async: false
      test "x", do: :ok
    end

    defmodule AsyncTest do
      use ExUnit.Case, async: true
      test "x", do: System.put_env("A", "1")
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 8 end)
  end
end
