require "./spec_helper"

include Crysterm

# Regression spec for BUGS11 #15: Escape on an embedded (non-popup) Menu whose
# highlight has been revealed must CANCEL, not ACTIVATE the highlighted action.
#
# `Mixin::ItemView#cancel_selected` (reached from Escape) emits BOTH `ActionItem`
# and `CancelItem`. Menu treats `ActionItem` as activation (its handler calls
# `activate_index`), so before the fix Escape fired the highlighted — possibly
# destructive — action. `Menu#cancel_selected` now emits only `CancelItem`.

private def menu_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS11 #15 Menu Escape (embedded menu cancels, does not activate)" do
  it "does not fire the highlighted action on Escape, and emits CancelItem" do
    s = menu_screen
    m = Crysterm::Widget::Menu.new(parent: s)
    triggered = false
    m.add("Delete file") { triggered = true }
    m.focus
    s.render

    cancelled = false
    m.on(Crysterm::Event::CancelItem) { cancelled = true }

    # Down reveals the highlight (first selection key just unhides it, selecting
    # the first item "Delete file").
    m.on_keypress Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Down)

    # Escape must back out of the menu, not run the highlighted action.
    m.on_keypress Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Escape)

    triggered.should be_false
    cancelled.should be_true
  end

  it "still activates the highlighted action on Enter (no regression)" do
    s = menu_screen
    m = Crysterm::Widget::Menu.new(parent: s)
    triggered = false
    m.add("Delete file") { triggered = true }
    m.focus
    s.render

    # Enter reveals the highlight on the first press...
    m.on_keypress Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Enter)
    triggered.should be_false
    # ...and activates it on the second.
    m.on_keypress Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Enter)
    triggered.should be_true
  end
end
