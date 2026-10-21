Code.require_file("credo/checks/no_dynamic_style.ex")

defmodule WhoseJam.Credo.Checks.NoDynamicStyleTest do
  use Credo.Test.Case

  alias WhoseJam.Credo.Checks.NoDynamicStyle

  @allowed [allowed_helpers: [:progress_style]]

  # The template body starts on line 5 of the generated module.
  defp check(template, params \\ @allowed) do
    """
    defmodule Sample do
      use Phoenix.Component
      def render(assigns) do
        ~H\"\"\"
    #{template}
        \"\"\"
      end
    end
    """
    |> to_source_file()
    |> run_check(NoDynamicStyle, params)
  end

  test "a static style attribute is fine" do
    ~S(<div style="width: 10%"></div>) |> check() |> refute_issues()
  end

  test "a style built from an assign is flagged at its line" do
    ~S(<div style={@x}></div>)
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end

  test "an interpolated style string is flagged" do
    ~S|<div style={"background: url(#{@art})"}></div>| |> check() |> assert_issue()
  end

  test "a call to an allowed helper on its own is fine" do
    ~S|<div style={progress_style(@prog)}></div>| |> check() |> refute_issues()
  end

  test "an allowed helper with nested calls and strings is still one call" do
    ~S|<div style={progress_style(Map.get(@prog, "a)b"))}></div>| |> check() |> refute_issues()
  end

  test "concatenating onto an allowed helper is flagged" do
    ~S|<div style={progress_style(@p) <> @song.album_art_url}></div>| |> check() |> assert_issue()

    ~S|<div style={progress_style(1) <> "; background:url(" <> @url <> ")"}></div>|
    |> check()
    |> assert_issue()
  end

  test "a helper that is not on the allowlist is flagged" do
    ~S|<div style={other_style(@p)}></div>| |> check() |> assert_issue()
    ~S|<div style={progress_style(@p)}></div>| |> check(allowed_helpers: []) |> assert_issue()
  end

  test "data-style is not a style attribute, and spaces around = do not hide one" do
    ~S|<div data-style={@x}></div>| |> check() |> refute_issues()
    ~S|<div style = {@x}></div>| |> check() |> assert_issue()
  end

  test "an allowed helper wrapped over several lines is fine" do
    """
    <div
      style={
        progress_style(@p)
      }
    ></div>
    """
    |> check()
    |> refute_issues()
  end

  test "every offending attribute is reported at its own line" do
    """
    <div style={@a}></div>
    <div class="x"></div>
    <div style={@b}></div>
    """
    |> check()
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.line_no) |> Enum.sort() == [5, 7]
    end)
  end
end
