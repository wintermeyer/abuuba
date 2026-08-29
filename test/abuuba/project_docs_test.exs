defmodule Abuuba.ProjectDocsTest do
  @moduledoc """
  Guards the legal ground rules.

  abuuba is MIT and Mastodon is AGPL-3.0, so a single copied file would change
  what the whole project may be used for. The prose in CONTRIBUTING.md states
  the rule; the last test here enforces it, by refusing to let an AGPL notice
  appear anywhere in the source tree.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read!(name), do: @root |> Path.join(name) |> File.read!()

  describe "LICENSE" do
    setup do
      %{license: read!("LICENSE")}
    end

    test "is the MIT license", %{license: license} do
      assert license =~ "MIT License"
      assert license =~ "Permission is hereby granted, free of charge"
      assert license =~ "WITHOUT WARRANTY OF ANY KIND"
    end

    test "names a copyright holder and a year", %{license: license} do
      assert license =~ ~r/Copyright \(c\) \d{4} \S/
    end
  end

  describe "CONTRIBUTING.md" do
    setup do
      %{contributing: read!("CONTRIBUTING.md")}
    end

    test "names the licence the rule exists to protect against", %{contributing: contributing} do
      assert contributing =~ "AGPL"
    end

    test "states that Mastodon may be read but never copied", %{contributing: contributing} do
      assert contributing =~ ~r/clean[- ]room/i
      assert contributing =~ ~r/never.{0,40}cop|not.{0,40}cop|no code/i
    end
  end

  describe "README.md" do
    setup do
      %{readme: read!("README.md")}
    end

    test "says what abuuba is", %{readme: readme} do
      assert readme =~ "Mastodon"
      assert readme =~ ~r/Elixir|Phoenix/
    end

    test "points at the licence and the contributing rules", %{readme: readme} do
      assert readme =~ "LICENSE"
      assert readme =~ "CONTRIBUTING"
    end
  end

  # Every text file, so a directory added later is guarded without anyone
  # remembering to extend a list here. `git ls-files` also keeps _build and
  # deps out without an exclusion list of its own, and a missing or failing git
  # makes the match below raise rather than quietly pass.
  #
  # The Ruby family is on this list although abuuba contains no Ruby of its
  # own, because the project this rule exists to guard against is written in
  # it. A copied .rb or .haml is the likeliest shape of the mistake, and it was
  # the one extension group missing when this was first written.
  @text_extensions ~w(.ex .exs .heex .eex .css .scss .js .mjs .cjs .jsx .ts .tsx
                      .po .pot .svg .json .yml .yaml .md .sql .html
                      .rb .rake .erb .haml .slim .sh .conf)

  # This file spells out the notices it searches for. Exempt exactly this one
  # path, never the directory it sits in.
  @self Path.relative_to(__ENV__.file, @root)

  # The clean-room rule, enforced rather than merely documented.
  #
  # Read this as a tripwire, not a sandbox. It catches a file copied out of an
  # AGPL project that carries a per-file licence header, which is the careless
  # case worth catching cheaply. It does not catch a copy from Mastodon
  # itself: not one of its ~1250 Ruby files carries a notice, so a verbatim
  # paste arrives clean with nothing to strip. Nor can any grep catch a copied
  # image, font, or sound. Staying clean is on the person writing the code;
  # this only stops the copy that announces itself.
  test "no AGPL notice appears anywhere in the tracked tree" do
    # `--others --exclude-standard` as well as the tracked files, because the
    # gate runs before `git add`: a file pasted in and checked before it is
    # staged was invisible to this test, which is the exact moment it needed to
    # be visible. Ignored paths stay out, so _build and deps are still skipped.
    {listed, 0} =
      System.cmd("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cd: @root
      )

    offenders =
      listed
      |> String.split("\0", trim: true)
      |> Enum.filter(&(Path.extname(&1) in @text_extensions))
      |> Enum.reject(&(&1 == @self))
      |> Enum.filter(
        &(read!(&1) =~ ~r/Affero General Public License|SPDX-License-Identifier:\s*AGPL/i)
      )

    assert offenders == [],
           "AGPL-licensed code must never be copied into abuuba. Offending files: " <>
             Enum.join(offenders, ", ")
  end
end
