require "./spec_helper"
require "file_utils"

include Crysterm

# `Widget::FileManager#reset` must return to the directory the manager was
# constructed with — not to `@file`, which tracks the most recently selected
# entry and can be a navigated-into subdirectory (or a regular file, whose
# `Dir.children` listing would fail and leave the reset a silent no-op).

private def fm_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::FileManager do
  it "#reset returns to the initial directory, not the last-navigated one" do
    base = File.tempname("crysterm-fm")
    Dir.mkdir_p File.join(base, "sub")

    begin
      s = fm_screen
      fm = Crysterm::Widget::FileManager.new(parent: s, cwd: base, keys: true)
      fm.refresh
      fm.cwd.should eq base

      # Navigate into "sub" by selecting its row and activating it.
      idx = fm.ritems.index(&.includes?("sub"))
      idx.should_not be_nil
      fm.selected = idx.not_nil!
      fm.enter_selected

      # Now inside the subdirectory; `@cwd` may carry a trailing slash, normalize to compare.
      fm.cwd.chomp('/').should eq File.join(base, "sub")

      fm.reset
      fm.cwd.should eq base
    ensure
      FileUtils.rm_rf base
    end
  end
end
