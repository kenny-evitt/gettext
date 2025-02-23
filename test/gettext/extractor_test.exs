defmodule Gettext.ExtractorTest do
  use ExUnit.Case
  alias Gettext.Extractor
  alias Gettext.PO
  alias Gettext.PO.Translation

  @pot_path "../../tmp/" |> Path.expand(__DIR__) |> Path.relative_to_cwd()

  describe "merge_pot_files/2" do
    test "merges two POT files" do
      paths = %{
        tomerge: Path.join(@pot_path, "tomerge.pot"),
        ignored: Path.join(@pot_path, "ignored.pot"),
        new: Path.join(@pot_path, "new.pot")
      }

      extracted_po_structs = [
        {paths.tomerge, %PO{translations: [%Translation{msgid: ["other"], msgstr: [""]}]}},
        {paths.new, %PO{translations: [%Translation{msgid: ["new"], msgstr: [""]}]}}
      ]

      write_file(paths.tomerge, """
      msgid "foo"
      msgstr ""
      """)

      write_file(paths.ignored, """
      msgid "ignored"
      msgstr ""
      """)

      structs =
        Extractor.merge_pot_files(extracted_po_structs, [paths.tomerge, paths.ignored], [])

      # Unchanged files are not returned
      assert List.keyfind(structs, paths.ignored, 0) == nil

      {_, contents} = List.keyfind(structs, paths.tomerge, 0)

      assert IO.iodata_to_binary(contents) == """
             msgid "foo"
             msgstr ""

             msgid "other"
             msgstr ""
             """

      {_, contents} = List.keyfind(structs, paths.new, 0)
      contents = IO.iodata_to_binary(contents)
      assert String.starts_with?(contents, "## This file is a PO Template file.")

      assert contents =~ """
             msgid "new"
             msgstr ""
             """
    end

    test "reports the filename if syntax error" do
      path = Path.join(@pot_path, "syntax_error.pot")

      write_file(path, """
      msgid "foo"

      msgid "bar"
      msgstr ""
      """)

      message = "syntax_error.pot:3: syntax error before: msgid"

      assert_raise Gettext.PO.SyntaxError, message, fn ->
        Extractor.merge_pot_files([{path, %PO{}}], [path], [])
      end
    end
  end

  describe "merge_template/2" do
    test "non-autogenerated translations are kept" do
      # No autogenerated translations
      t1 = %Translation{msgid: ["foo"], msgstr: ["bar"]}
      t2 = %Translation{msgid: ["baz"], msgstr: ["bong"]}
      t3 = %Translation{msgid: ["a", "b"], msgstr: ["c", "d"]}
      old = %PO{translations: [t1]}
      new = %PO{translations: [t2, t3]}

      assert Extractor.merge_template(old, new, []) == %PO{translations: [t1, t2, t3]}
    end

    test "whitelisted translations are kept" do
      t1 = %Translation{
        msgid: ["foo"],
        msgstr: ["bar"],
        references: [{"foo.ex", 1}],
        flags: MapSet.new(["elixir-format"])
      }

      t2 = %Translation{
        msgid: ["baz"],
        msgstr: ["bong"],
        references: [{"web/static/js/app.js", 10}]
      }

      old = %PO{translations: [t1, t2]}
      new = %PO{}

      assert Extractor.merge_template(old, new, excluded_refs_from_purging: ~r{^web/static/}) ==
               %PO{translations: [t2]}
    end

    test "obsolete autogenerated translations are discarded" do
      # Autogenerated translations
      t1 = %Translation{msgid: ["foo"], msgstr: ["bar"], flags: MapSet.new(["elixir-format"])}
      t2 = %Translation{msgid: ["baz"], msgstr: ["bong"]}
      old = %PO{translations: [t1]}
      new = %PO{translations: [t2]}

      assert Extractor.merge_template(old, new, []) == %PO{translations: [t2]}
    end

    test "matching translations are merged" do
      flags = MapSet.new(["elixir-format"])

      ts1 = [
        %Translation{
          msgid: ["matching autogenerated"],
          references: [{"foo.ex", 2}],
          flags: flags,
          extracted_comments: ["#. Foo"]
        },
        %Translation{msgid: ["non-matching autogenerated"], flags: flags},
        %Translation{msgid: ["non-autogenerated"], references: [{"foo.ex", 4}]}
      ]

      ts2 = [
        %Translation{msgid: ["non-matching non-autogenerated"]},
        %Translation{
          msgid: ["matching autogenerated"],
          references: [{"foo.ex", 3}],
          extracted_comments: ["#. Bar"]
        }
      ]

      assert Extractor.merge_template(%PO{translations: ts1}, %PO{translations: ts2}, []) == %PO{
               translations: [
                 %Translation{
                   msgid: ["matching autogenerated"],
                   references: [{"foo.ex", 3}],
                   flags: flags,
                   extracted_comments: ["#. Bar"]
                 },
                 %Translation{msgid: ["non-autogenerated"], references: [{"foo.ex", 4}]},
                 %Translation{msgid: ["non-matching non-autogenerated"]}
               ]
             }
    end

    test "headers are taken from the oldest PO file" do
      po1 = %PO{headers: ["Last-Translator: Foo", "Content-Type: text/plain"]}
      po2 = %PO{headers: ["Last-Translator: Bar"]}

      assert Extractor.merge_template(po1, po2, []) == %PO{
               headers: [
                 "Last-Translator: Foo",
                 "Content-Type: text/plain"
               ]
             }
    end

    test "non-empty msgstrs raise an error" do
      po1 = %PO{translations: [%Translation{msgid: "foo", msgstr: "bar"}]}
      po2 = %PO{translations: [%Translation{msgid: "foo", msgstr: "bar"}]}

      msg = "translation with msgid 'foo' has a non-empty msgstr"

      assert_raise Gettext.Error, msg, fn ->
        Extractor.merge_template(po1, po2, [])
      end
    end

    test "order is kept as much as possible" do
      # Old translations are kept in the order we find them (except the ones we
      # remove), and all the new ones are appended after them.
      foo_translation = %Translation{msgid: ["foo"], references: [{"foo.ex", 1}]}

      msgid = "Live stream available from %{provider}"

      po1 = %PO{
        translations: [
          %Translation{msgid: [msgid], references: [{"reminder.ex", 160}]},
          foo_translation
        ]
      }

      po2 = %PO{
        translations: [
          %Translation{msgid: ["new translation"]},
          foo_translation,
          %Translation{msgid: [msgid], references: [{"live_streaming.ex", 40}]}
        ]
      }

      %PO{translations: [t1, ^foo_translation, t2]} = Extractor.merge_template(po1, po2, [])

      assert t1.msgid == [msgid]
      assert t1.references == [{"live_streaming.ex", 40}]
      assert t2.msgid == ["new translation"]
    end
  end

  test "extraction process" do
    refute Extractor.extracting?()
    Extractor.enable()
    assert Extractor.extracting?()

    code = """
    defmodule Gettext.ExtractorTest.MyGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule Gettext.ExtractorTest.MyOtherGettext do
      use Gettext, otp_app: :test_application, priv: "translations"
    end

    defmodule Foo do
      import Gettext.ExtractorTest.MyGettext
      require Gettext.ExtractorTest.MyOtherGettext

      def bar do
        gettext_comment "some comment"
        gettext_comment "some other comment"
        gettext "foo"
        dngettext "errors", "one error", "%{count} errors", 2
        gettext_comment "one more comment"
        gettext "foo"
        Gettext.ExtractorTest.MyOtherGettext.dgettext "greetings", "hi"
      end
    end
    """

    Code.compile_string(code, Path.join(File.cwd!(), "foo.ex"))

    expected = [
      {"priv/gettext/default.pot",
       ~S"""
       msgid ""
       msgstr ""

       #. some comment
       #. some other comment
       #. one more comment
       #, elixir-format
       #: foo.ex:16 foo.ex:19
       msgid "foo"
       msgstr ""
       """},
      {"priv/gettext/errors.pot",
       ~S"""
       msgid ""
       msgstr ""

       #, elixir-format
       #: foo.ex:17
       msgid "one error"
       msgid_plural "%{count} errors"
       msgstr[0] ""
       msgstr[1] ""
       """},
      {"translations/greetings.pot",
       ~S"""
       msgid ""
       msgstr ""

       #, elixir-format
       #: foo.ex:20
       msgid "hi"
       msgstr ""
       """}
    ]

    # No backends for the unknown app
    assert [] = Extractor.pot_files(:unknown, [])

    pot_files = Extractor.pot_files(:test_application, [])
    dumped = Enum.map(pot_files, fn {k, v} -> {k, IO.iodata_to_binary(v)} end)

    # We check that dumped strings end with the `expected` string because
    # there's the informative comment at the start of each dumped string.
    Enum.each(dumped, fn {path, contents} ->
      {^path, expected_contents} = List.keyfind(expected, path, 0)
      assert String.starts_with?(contents, "## This file is a PO Template file.")
      assert contents =~ expected_contents
    end)
  after
    Extractor.disable()
    refute Extractor.extracting?()
  end

  test "warns on conflicting backends" do
    refute Extractor.extracting?()
    Extractor.enable()
    assert Extractor.extracting?()

    code = """
    defmodule Gettext.ExtractorConflictTest.MyGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule Gettext.ExtractorConflictTest.MyOtherGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule FooConflict do
      import Gettext.ExtractorConflictTest.MyGettext
      require Gettext.ExtractorConflictTest.MyOtherGettext

      def bar do
        gettext "foo"
        Gettext.ExtractorConflictTest.MyOtherGettext.gettext "foo"
      end
    end
    """

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Code.compile_string(code, Path.join(File.cwd!(), "foo_conflict.ex"))
             Extractor.pot_files(:test_application, [])
           end) =~
             "the Gettext backend Gettext.ExtractorConflictTest.MyGettext has the same :priv directory as Gettext.ExtractorConflictTest.MyOtherGettext"
  after
    Extractor.disable()
  end

  defp write_file(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
  end
end
