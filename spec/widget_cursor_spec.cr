require "./spec_helper"

include Crysterm

# Per-widget cursor: a `Widget` may carry its own `Cursor`, and the cursor that
# is actually used/drawn is resolved by `Window#active_cursor` — the focused
# widget's cursor if it has one, otherwise the screen's default `Window#cursor`.

# A `Window` backed by in-memory IOs, so constructing one neither writes escape
# sequences to the real test terminal nor reads from it (see `cursor_spec.cr`).
def cursor_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "per-widget cursor" do
  it "defaults to no override, falling back to the screen cursor" do
    s = cursor_mem_screen
    w = Crysterm::Widget::Box.new parent: s, keys: true
    w.focus

    s.focused.should be(w)
    w.cursor.should be_nil
    # Fallback: with no widget override, the active cursor IS the screen default.
    s.active_cursor.should be(s.cursor)
  end

  it "uses the focused widget's own cursor once it defines one" do
    s = cursor_mem_screen
    w = Crysterm::Widget::Box.new parent: s, keys: true
    w.focus

    w.set_cursor Tput::Namespace::CursorShape::Line
    w.cursor.should_not be_nil
    s.active_cursor.should be(w.cursor.not_nil!)
    s.active_cursor.shape.line?.should be_true
    # The screen default is untouched.
    s.cursor.shape.block?.should be_true
  end

  it "reverts to the screen default after reset_cursor" do
    s = cursor_mem_screen
    w = Crysterm::Widget::Box.new parent: s, keys: true
    w.focus

    w.cursor!.shape = :underline
    s.active_cursor.should be(w.cursor.not_nil!)

    w.reset_cursor
    w.cursor.should be_nil
    s.active_cursor.should be(s.cursor)
  end

  it "keeps independent cursors per widget; the active one tracks focus" do
    s = cursor_mem_screen
    a = Crysterm::Widget::Box.new parent: s, keys: true
    b = Crysterm::Widget::Box.new parent: s, keys: true

    a.cursor!.shape = :line
    b.cursor!.shape = :underline

    a.focus
    s.active_cursor.shape.line?.should be_true

    b.focus
    s.active_cursor.shape.underline?.should be_true
  end
end
