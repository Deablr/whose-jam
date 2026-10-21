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

  test "an allowed helper's string arguments may contain braces, parens and escaped quotes" do
    ~S|<div style={progress_style("}")}></div>| |> check() |> refute_issues()
    ~S|<div style={progress_style("a)b\"}")}></div>| |> check() |> refute_issues()
    ~S|<div style={progress_style(%{a: 1})}></div>| |> check() |> refute_issues()
  end

  test "char literals cannot hide a concatenation onto an allowed helper" do
    ~S|<div style={progress_style(?() <> @x <> to_string(?))}></div>| |> check() |> assert_issue()
    ~S|<div style={progress_style(?") <> @x <> to_string(?")}></div>| |> check() |> assert_issue()
  end

  test "a body that cannot be parsed is a violation, not a pass" do
    ~S|<div style={"a" <> <<?">> <> @song.art}></div>| |> check() |> assert_issue()
    ~S|<div style={progress_style(1)></div>| |> check() |> assert_issue()
    ~S|<div style={}></div>| |> check() |> assert_issue()
  end

  test "pipes, remote calls and bare variables are not a call to an allowed helper" do
    ~S'''
    <div style={@p |> progress_style()}></div>
    '''
    |> check()
    |> assert_issue()

    ~S|<div style={Foo.progress_style(@p)}></div>| |> check() |> assert_issue()
    ~S|<div style={progress_style}></div>| |> check() |> assert_issue()
  end

  test "attribute names are matched case-insensitively" do
    ~S|<div STYLE={@x}></div>| |> check() |> assert_issue()
    ~S|<div Style={@x}></div>| |> check() |> assert_issue()
  end

  test "line numbers are right for ~H heredocs and inline sigils" do
    "defmodule Sample do\n  def render(assigns) do\n    ~H\'\'\'\n    <div style={@x}></div>\n    \'\'\'\n  end\nend\n"
    |> to_source_file()
    |> run_check(NoDynamicStyle, @allowed)
    |> assert_issue(fn issue -> assert issue.line_no == 4 end)

    "defmodule Sample do\n  def render(assigns) do\n    ~H\"<div style={@x}></div>\"\n  end\nend\n"
    |> to_source_file()
    |> run_check(NoDynamicStyle, @allowed)
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end
end
