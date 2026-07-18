require "./spec_helper"

include Crysterm

# Regression specs for the BUGS7 "Dialog & Widget Teardown Lifecycle" fixes —
# window-level state that must be released when a widget is destroyed *outside*
# its normal accept/cancel path.
#
# * `ColorDialog` destroyed mid-`pick` must drop its window `KeyPress` handler
#   and modal grab, and never fire the pick callback on the dead dialog.
# * An item view's incremental-search `LineEdit` (docked on the *window*) must be
#   removed when the list is destroyed.
# * `SplashScreen`'s key-dismiss handler must (re)wire on `Attached` and be removed
#   on `#destroy`.
# * A page-less `Wizard` must not expose a working "Finish" (`advance` no-op).

private def life_window(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

private def enter_key
  Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
end

describe "BUGS7 ColorDialog teardown outside accept/cancel" do
  it "fires the pick callback on a live Enter (control)" do
    s = life_window
    dlg = Widget::ColorDialog.new parent: s
    called = 0
    dlg.get_color { |_| called += 1 }
    s.emit Crysterm::Event::KeyPress, enter_key
    called.should eq 1 # Enter -> accept -> finish -> callback
  end

  it "does not fire the pick callback after the dialog is destroyed" do
    s = life_window
    dlg = Widget::ColorDialog.new parent: s
    called = 0
    dlg.get_color { |_| called += 1 }

    dlg.destroy
    s.emit Crysterm::Event::KeyPress, enter_key # handler must be gone
    called.should eq 0
    s.grabbing?.should be_false # no leaked modal grab
  end
end

describe "BUGS7 item-view search box is not orphaned on destroy" do
  it "removes the window-docked search LineEdit when the list is destroyed" do
    s = life_window
    list = Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 6,
      items: ["alpha", "beta", "gamma"]
    s._render

    list.start_search # lazily builds + appends the search box to the window
    box = s.children.select(Widget::LineEdit).first
    box.submit # finish the search read: the box hides but stays appended (the leak)
    s.children.select(Widget::LineEdit).size.should eq 1

    list.destroy
    s.children.select(Widget::LineEdit).should be_empty
  end
end

describe "BUGS7 SplashScreen key-dismiss wiring/teardown" do
  it "wires the key-dismiss handler on Attach when constructed detached" do
    s = life_window
    splash = Widget::SplashScreen.new # no parent/window at construction
    completed = 0
    splash.on(Crysterm::Event::Completed) { completed += 1 }

    s.append splash # Attach installs the window-level key handler
    s.emit Crysterm::Event::KeyPress, enter_key
    completed.should eq 1 # a key dismissed it (was silently dead pre-fix)
  end

  it "does not dismiss via a leaked handler after destroy" do
    s = life_window
    splash = Widget::SplashScreen.new parent: s
    completed = 0
    splash.on(Crysterm::Event::Completed) { completed += 1 }

    splash.destroy
    s.emit Crysterm::Event::KeyPress, enter_key
    completed.should eq 0 # handler removed; no finish/Complete on a dead splash
  end
end

describe "BUGS7 page-less Wizard does not complete" do
  it "advance is a no-op with zero pages" do
    s = life_window
    wiz = Widget::Wizard.new parent: s
    wiz.page_count.should eq 0
    completes = 0
    wiz.on(Crysterm::Event::Completed) { completes += 1 }

    wiz.advance
    completes.should eq 0
  end

  it "completes normally once on the last real page (no regression)" do
    s = life_window
    wiz = Widget::Wizard.new parent: s
    wiz.add_page Widget::Box.new, "one"
    completes = 0
    wiz.on(Crysterm::Event::Completed) { completes += 1 }

    wiz.advance # on the single (last) page -> Complete
    completes.should eq 1
  end
end
