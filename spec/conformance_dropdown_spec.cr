require "./spec_helper"

include Crysterm

# FORMAL-WIDGETS Part A / Piece 5 — shared behavioral conformance for the
# "dropdown family" (`Menu`, `ComboBox`, `Completer`). This is Part A's own
# governance piece (the four *Part B* family matrices already landed under B8);
# it retroactively pins the invariants the already-shipped refactors rely on:
# `Overlay::DismissSession` (the grab + click-away lifecycle, adopted by all
# three) and `Mixin::ItemView::WheelMode` (the wheel/hover policy the combo and
# completer share). A single interaction script runs against every member through
# a tiny adapter, so an invariant that *should* hold family-wide is proven
# family-wide instead of hoped — an accidental divergence fails here.
#
# Deliberate differences are adapter capability flags, exactly as in the ranged /
# paged / checkable / dialog matrices:
#   * `scroll_view` — only `ComboBox`/`Completer` use
#     `WheelMode::ScrollViewUnderPointer` (scroll the viewport under a stationary
#     pointer, keep the last row wheel-reachable). `Menu` keeps `MoveSelection`
#     (wheel == arrow keys), so the "reach the last entry by the wheel" case is
#     scoped to the scroll-view members.
# The universal invariants (opens/reports open?, dismisses on an outside press,
# dismisses on Escape, wheeling never dismisses) hold for all three.

private def dd_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def dd_kp(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

private def dd_press(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

private def dd_wheel(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::WheelDown, ::Tput::Mouse::Button::None, x, y, source: :test)
end

# One family member's adapter. Every closure is built fresh per example so no
# state leaks between cases (mirrors the ranged/paged matrices). `scroll_view`
# marks the `ScrollViewUnderPointer` members (combo/completer) whose wheel must
# keep the last row reachable — the exact behavior `WheelMode` consolidated.
private record DropdownCase,
  name : String,
  make : Proc(DropdownAdapter),
  scroll_view : Bool

# The live handle an adapter's `make` returns. `outside` is a coordinate the
# popup provably does not cover (checked below), so an outside-press example is
# never a false negative from a mis-placed popup.
private record DropdownAdapter,
  open : Proc(Nil),
  is_open : Proc(Bool),
  selected : Proc(Int32),
  item_count : Proc(Int32),
  render : Proc(Nil),
  wheel_down : Proc(Nil),
  press_outside : Proc(Nil),
  outside_covered : Proc(Bool),
  escape : Proc(Nil)

private def it_behaves_like_a_dropdown(c : DropdownCase)
  describe c.name do
    it "opens and reports open?" do
      a = c.make.call
      a.is_open.call.should be_false
      a.open.call
      a.is_open.call.should be_true
    end

    it "dismisses on a press outside the popup" do
      a = c.make.call
      a.open.call
      a.render.call
      a.outside_covered.call.should be_false # the outside point is really outside
      a.press_outside.call
      a.is_open.call.should be_false
    end

    it "dismisses on Escape" do
      a = c.make.call
      a.open.call
      a.render.call
      a.escape.call
      a.is_open.call.should be_false
    end

    it "wheeling over the open list moves the selection and never dismisses" do
      a = c.make.call
      a.open.call
      a.render.call
      before = a.selected.call
      a.wheel_down.call
      a.is_open.call.should be_true # a wheel notch must never close the drop-down
      a.selected.call.should be > before
    end

    if c.scroll_view
      it "keeps the last row wheel-reachable (ScrollViewUnderPointer)" do
        a = c.make.call
        a.open.call
        a.render.call
        (a.item_count.call > 1).should be_true
        # Wheel down more times than there are entries: the last row must be
        # reachable by the wheel alone (the edge-stepping fallback in
        # `scroll_view_under_pointer`).
        (a.item_count.call + 6).times { a.wheel_down.call }
        a.selected.call.should eq a.item_count.call - 1
        a.is_open.call.should be_true
      end
    end
  end
end

describe "Dropdown conformance (FORMAL-WIDGETS Part A / Piece 5)" do
  # --- Menu: is its own popup; MoveSelection wheel; modal grab. ---
  it_behaves_like_a_dropdown DropdownCase.new(
    name: "Menu",
    scroll_view: false,
    make: -> {
      s = dd_screen
      menu = Crysterm::Widget::Menu.new parent: s, width: 14, height: 6
      %w[Open Save Close Quit Print Help].each { |l| menu.add_action l }
      DropdownAdapter.new(
        open: -> { menu.popup 2, 2; nil },
        is_open: -> { menu.visible? && menu.@popup_mode },
        selected: -> { menu.current_index },
        item_count: -> { menu.@items.size },
        render: -> { s._render; nil },
        wheel_down: -> { dd_wheel s, menu.aleft + 2, menu.atop + menu.itop + 1; nil },
        press_outside: -> { dd_press s, 78, 22; nil },
        outside_covered: -> { menu.contains_point? 78, 22 },
        escape: -> { menu.on_keypress dd_kp('\0', ::Tput::Key::Escape); nil },
      )
    }
  )

  # --- ComboBox (non-editable): owns one popup child; ScrollViewUnderPointer. ---
  it_behaves_like_a_dropdown DropdownCase.new(
    name: "ComboBox",
    scroll_view: true,
    make: -> {
      s = dd_screen
      cb = Crysterm::Widget::ComboBox.new parent: s, top: 3, left: 4, width: 16, height: 1,
        editable: false, options: %w[Red Green Blue Cyan Magenta Maroon Teal Olive]
      cb.focus
      DropdownAdapter.new(
        open: -> { cb.show_popup; nil },
        is_open: -> { cb.open? },
        selected: -> { cb.popup_widget.not_nil!.as(Crysterm::Widget::ComboBox::Popup).current_index },
        item_count: -> { cb.popup_widget.not_nil!.@items.size },
        render: -> { s.render; nil },
        wheel_down: -> {
          pop = cb.popup_widget.not_nil!
          dd_wheel s, pop.aleft + 2, pop.atop + pop.itop + 1; nil
        },
        press_outside: -> { dd_press s, 78, 22; nil },
        outside_covered: -> { cb.popup_widget.not_nil!.contains_point? 78, 22 },
        # Non-editable combo hands focus to the popup, so Escape routes through it
        # (ItemView cancel path -> `ComboBox#hide_popup`).
        escape: -> { cb.popup_widget.not_nil!.on_keypress dd_kp('\0', ::Tput::Key::Escape); nil },
      )
    }
  )

  # --- Completer: not a widget; attaches to a LineEdit; ScrollViewUnderPointer;
  #     NO modal grab (its box must keep reacting). ---
  it_behaves_like_a_dropdown DropdownCase.new(
    name: "Completer",
    scroll_view: true,
    make: -> {
      s = dd_screen
      box = Crysterm::Widget::LineEdit.new parent: s, top: 3, left: 6, width: 18, height: 1
      completer = Crysterm::Completer.new %w[Crystal Ruby Rust Python Perl PHP Go Groovy Java JavaScript Kotlin Lua]
      completer.attach box
      box.focus
      DropdownAdapter.new(
        # Down opens the popup on the whole model (combo-box style).
        open: -> { box.emit Crysterm::Event::KeyPress, dd_kp('\0', ::Tput::Key::Down); nil },
        is_open: -> { completer.open? },
        selected: -> { completer.@popup.not_nil!.current_index },
        item_count: -> { completer.@popup.not_nil!.@items.size },
        render: -> { s._render; nil },
        wheel_down: -> {
          pop = completer.@popup.not_nil!
          dd_wheel s, pop.aleft + 2, pop.atop + pop.itop + 1; nil
        },
        press_outside: -> { dd_press s, 78, 22; nil },
        outside_covered: -> { completer.@popup.not_nil!.contains_point? 78, 22 },
        escape: -> { box.emit Crysterm::Event::KeyPress, dd_kp('\0', ::Tput::Key::Escape); nil },
      )
    }
  )
end
