require "./spec_helper"
require "file_utils"

include Crysterm

# `Widget::FileManager#open_selected` must resolve the path from the entry's
# *real* name, not by reverse-engineering it from the decorated row text. That
# text carries `{...}` color tags plus a `/`/`@` suffix, so:
#   * a name containing a `{...}` tag-like sequence would be mangled by
#     `clean_tags` (which strips it as a style tag), and
#   * a regular file whose name ends in `@` would have the `@` stripped as if it
#     were the symlink decoration,
# both yielding a wrong (non-existent) target. Driven headlessly over in-memory
# IOs against a real temp directory tree.

private def fm_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::FileManager do
  it "navigates into a directory whose name contains a {...} tag-like sequence" do
    base = File.tempname("crysterm-fm-tag")
    dir = File.join(base, "mail{x}")
    Dir.mkdir_p dir

    begin
      s = fm_screen
      fm = Crysterm::Widget::FileManager.new(parent: s, cwd: base, keys: true)
      fm.refresh

      idx = fm.ritems.index(&.includes?("mail"))
      idx.should_not be_nil
      fm.selected = idx.not_nil!
      fm.enter_selected

      # The clean_tags reconstruction would strip the `{x}` and land on a
      # non-existent "mailc"-style path, leaving us stuck in `base`.
      fm.cwd.chomp('/').should eq dir
    ensure
      FileUtils.rm_rf base
    end
  end

  it "opens a regular file whose name ends in @ at its true path" do
    base = File.tempname("crysterm-fm-at")
    Dir.mkdir_p base
    target = File.join(base, "data@")
    File.write target, "x"

    begin
      s = fm_screen
      fm = Crysterm::Widget::FileManager.new(parent: s, cwd: base, keys: true)
      fm.refresh

      idx = fm.ritems.index(&.includes?("data"))
      idx.should_not be_nil
      fm.selected = idx.not_nil!

      opened = nil.as(String?)
      fm.on(Crysterm::Event::OpenFile) { |e| opened = e.path }
      fm.enter_selected

      # The `@\z` strip would have produced base/"data" (missing) and emitted
      # nothing; the real path must come through intact.
      opened.should eq target
      fm.path.should eq target
    ensure
      FileUtils.rm_rf base
    end
  end
end
