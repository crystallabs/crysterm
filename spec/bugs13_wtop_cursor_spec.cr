require "./spec_helper"

include Crysterm

# Regression spec for BUGS13 W15 — the widget cursor convenience methods
# (`cursor_shape`/`cursor_color`/`show_cursor`/`hide_cursor`,
# src/widget_cursor.cr) were `window?.try`-guarded, so calling them on a
# DETACHED widget silently discarded the setting — contradicting the module's
# "recorded and applied on focus" contract and the always-recording
# `cursor!.shape=` path. They now record on the widget's own cursor while
# detached; the setting takes effect once attached and focused.

private def cursor_screen(w = 20, h = 6)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

# A widget with no window: a parentless construction falls back to the global
# window (`determine_window`), so build attached and then detach.
private def detached_box(s)
  w = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
  s.remove w
  w.window?.should be_nil
  w
end

describe "BUGS13 W15: cursor settings on a detached widget are recorded" do
  it "records shape and blink on the widget's own cursor" do
    s = cursor_screen
    w = detached_box s
    w.cursor.should be_nil

    w.cursor_shape Tput::CursorShape::Underline, true

    c = w.cursor.not_nil!
    c.shape.should eq Tput::CursorShape::Underline
    c.blink.should be_true
    c._set.should be_false # not applied yet — no window
  ensure
    s.try &.destroy
  end

  it "records color on the widget's own cursor" do
    s = cursor_screen
    w = detached_box s
    w.cursor_color "red"
    w.cursor.not_nil!.style.fg.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "records show/hide on the widget's own cursor" do
    s = cursor_screen
    w = detached_box s
    w.show_cursor
    w.cursor.not_nil!._hidden.should be_false
    w.hide_cursor
    w.cursor.not_nil!._hidden.should be_true
  ensure
    s.try &.destroy
  end

  it "the recorded settings survive attachment and drive the active cursor" do
    s = cursor_screen
    w = detached_box s
    w.cursor_shape Tput::CursorShape::Underline, true
    w.cursor_color "red"

    s.append w
    w.focus

    # The widget's own (recorded) cursor is now the active one, unchanged.
    s.active_cursor.should be w.cursor
    c = w.cursor.not_nil!
    c.shape.should eq Tput::CursorShape::Underline
    c.blink.should be_true
    c.style.fg.should_not be_nil

    # Applying the active cursor consumes the recorded settings.
    s.apply_cursor
    c._set.should be_true
  ensure
    s.try &.destroy
  end
end
