require "./spec_helper"

include Crysterm

# Regression for BUGS17 B17-42 — after Escape dismisses the completion popup,
# a following key that does NOT change the box text (cursor movement) must not
# reopen it; only an actual text change reopens.
#
# Unlike bugs13_al_popup_lifecycle_spec (which never focuses the box, so the
# per-keystroke filter is never installed), this focuses the box so a real
# FocusIn installs the filter — the only path on which the bug exists.

private def esc_screen(w = 60, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS17 B17-42: Completer stays dismissed on non-modifying keys after Escape" do
  it "does not reopen on cursor keys but reopens on a text change" do
    s = esc_screen
    other = Crysterm::Widget::Button.new parent: s, top: 0, left: 0, width: 8, height: 1, content: "Other"
    box = Crysterm::Widget::LineEdit.new parent: s, top: 5, left: 2, width: 20, height: 1
    comp = Crysterm::Completer.new %w[apple apricot banana]
    comp.attach box
    s._render

    # Park focus off the box, then focus it so a genuine FocusIn installs the
    # per-keystroke filter and enters read mode (the auto-focus at first render
    # does not drive that path).
    other.focus
    s._render
    box.focus
    s._render

    # Type "ap" -> popup opens on the matches (apple/apricot).
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('a')
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('p')
    box.value.should eq "ap"
    comp.open?.should be_true

    # Escape dismisses it.
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)
    comp.open?.should be_false

    # Cursor movement leaves the text unchanged: the popup must stay closed.
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Left)
    comp.open?.should be_false
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Right)
    comp.open?.should be_false
    box.value.should eq "ap" # text truly unchanged by the cursor keys

    # A real text change reopens it.
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('p')
    box.value.should eq "app"
    comp.open?.should be_true
  end
end
