require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 core findings C2, C4, C18, C21
# (src/window_mouse.cr, src/window_drag.cr):
#
# C2  — painting flattens a NESTED z-index into the outermost z-indexed
#       ancestor's plane, so `hit_layer` must rank a candidate by that
#       OUTERMOST ancestor's z too: an occluded child with a high nested z
#       must not steal clicks from the plane actually painted above it.
# C4  — double-click detection must be per-button: a right-then-left pair at
#       the same cell used to read as `click_count == 2` on the left click.
# C18 — a drag commits its Drop only on the ARMING button's release (a stray
#       other-button tap mid-gesture is swallowed); Escape cancels a
#       mouse-sensor drag; a mouse capture likewise ends only on the arming
#       button's release.
# C21 — the drag ghost is sized by terminal COLUMNS (`Unicode.width`), not
#       codepoints, so a CJK/emoji label isn't clipped mid-glyph.

private def b13m_window(w = 60, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b13m_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def b13m_down(s, x, y, button = ::Tput::Mouse::Button::Left)
  s.dispatch_mouse b13m_mouse(::Tput::Mouse::Action::Down, x, y, button)
end

private def b13m_up(s, x, y, button = ::Tput::Mouse::Button::Left)
  s.dispatch_mouse b13m_mouse(::Tput::Mouse::Action::Up, x, y, button)
end

private def b13m_move(s, x, y)
  s.dispatch_mouse b13m_mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

private def b13m_key(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

describe "BUGS13 C2: hit-test ranks by the OUTERMOST z-indexed ancestor" do
  it "an occluded child's high nested z-index cannot steal the click from the plane above" do
    s = b13m_window
    begin
      # r1 (z 1) is painted into the z=1 plane; c1 nests INSIDE r1 with z 9 —
      # painting flattens it into r1's plane (only the first z-indexed widget
      # on the walk down is deferred), so visually r2 (z 2) is on top of both.
      r1 = Widget::Box.new parent: s, left: 5, top: 5, width: 12, height: 6
      r1.add_css_class "b13c2r1"
      c1 = Widget::Box.new parent: r1, left: 0, top: 0, width: 10, height: 4
      c1.add_css_class "b13c2c1"
      r2 = Widget::Box.new parent: s, left: 5, top: 5, width: 8, height: 6
      r2.add_css_class "b13c2r2"
      r1.clickable = true
      c1.clickable = true
      r2.clickable = true
      s.stylesheet = ".b13c2r1 { z-index: 1; } " \
                     ".b13c2c1 { z-index: 9; } " \
                     ".b13c2r2 { z-index: 2; }"
      s.repaint # hit-testing uses the painted lpos

      # (8, 7) lies inside r1, c1 AND r2. The z=2 plane is painted above the
      # z=1 plane, so r2 must win — pre-fix, c1's own nested z 9 out-ranked it.
      s.widget_at(8, 7).should eq r2

      # Control: (13, 6) is covered only by the z=1 plane (r2 ends at col 13,
      # half-open); within that plane the nested child is the topmost hit.
      s.widget_at(13, 6).should eq c1
    ensure
      s.destroy
    end
  end
end

describe "BUGS13 C4: double-click detection is per-button" do
  it "a right-then-left pair at the same cell is NOT a double left click" do
    s = b13m_window
    begin
      box = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
      box.clickable = true
      s.repaint

      b13m_down s, 2, 1, ::Tput::Mouse::Button::Right
      s.click_count.should eq 1

      # Same widget, same cell, well within the double-click interval — but a
      # DIFFERENT button: this is a first left click, not a double.
      b13m_down s, 2, 1, ::Tput::Mouse::Button::Left
      s.click_count.should eq 1

      # A same-button repeat still advances to a double click.
      b13m_down s, 2, 1, ::Tput::Mouse::Button::Left
      s.click_count.should eq 2
    ensure
      s.destroy
    end
  end
end

describe "BUGS13 C18: drag ends only on the arming button; Escape cancels a mouse drag" do
  it "an RMB tap mid-LMB-drag neither commits the Drop nor ends the drag" do
    s = b13m_window
    begin
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.drag_mode = :transfer; source.draggable = true
      target = Widget::Box.new parent: s, left: 30, top: 0, width: 10, height: 4
      target.on(Crysterm::Event::DragOver, &.accept)
      drops = 0
      target.on(Crysterm::Event::Drop) { drops += 1 }
      ends = [] of Bool
      source.on(Crysterm::Event::DragEnd) { |e| ends << e.dropped? }

      b13m_down s, 2, 1, ::Tput::Mouse::Button::Left # arm
      b13m_move s, 32, 1                             # promote to drag, over the target
      s.drag_session.should_not be_nil

      # Stray right-button tap mid-gesture: both reports are swallowed by the
      # in-flight drag — no Drop, drag still active (pre-fix the up committed
      # the Drop at the pointer).
      b13m_down s, 32, 1, ::Tput::Mouse::Button::Right
      b13m_up s, 32, 1, ::Tput::Mouse::Button::Right
      s.drag_session.should_not be_nil
      drops.should eq 0
      ends.empty?.should be_true

      # The ARMING button's release commits.
      b13m_up s, 32, 1, ::Tput::Mouse::Button::Left
      s.drag_session.should be_nil
      drops.should eq 1
      ends.should eq [true]
    ensure
      s.destroy
    end
  end

  it "Escape cancels a mouse-sensor drag (no Drop, DragEnd not dropped)" do
    s = b13m_window
    begin
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.drag_mode = :transfer; source.draggable = true
      target = Widget::Box.new parent: s, left: 30, top: 0, width: 10, height: 4
      target.on(Crysterm::Event::DragOver, &.accept)
      drops = 0
      target.on(Crysterm::Event::Drop) { drops += 1 }
      ends = [] of Bool
      source.on(Crysterm::Event::DragEnd) { |e| ends << e.dropped? }

      b13m_down s, 2, 1, ::Tput::Mouse::Button::Left
      b13m_move s, 32, 1
      s.drag_session.should_not be_nil

      # Pre-fix, `_drag_key_handled` early-returned for non-keyboard sensors,
      # so a mouse drag had no cancel path at all.
      s._drag_key_handled(b13m_key('\0', ::Tput::Key::Escape)).should be_true
      s.drag_session.should be_nil
      drops.should eq 0
      ends.should eq [false]
    ensure
      s.destroy
    end
  end

  it "a mouse capture ends only on the arming button's release" do
    s = b13m_window
    begin
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
      w.clickable = true
      moves = 0
      w.on(Crysterm::Event::Mouse) do |e|
        s.capture_mouse w if e.action.down?
        moves += 1 if e.action.move?
      end
      s.repaint

      b13m_down s, 2, 1, ::Tput::Mouse::Button::Left # press arms the capture
      b13m_move s, 40, 10                            # outside w, still delivered
      moves.should eq 1

      # A right-button release mid-drag-select must NOT cut the capture short:
      # motion afterwards still routes to the captor.
      b13m_up s, 40, 10, ::Tput::Mouse::Button::Right
      b13m_move s, 41, 10
      moves.should eq 2

      # The arming (left) button's release ends the capture; further motion
      # outside the widget is no longer delivered.
      b13m_up s, 41, 10, ::Tput::Mouse::Button::Left
      b13m_move s, 42, 10
      moves.should eq 2
    ensure
      s.destroy
    end
  end
end

describe "BUGS13 C21: drag ghost sized by terminal columns, not codepoints" do
  it "gives a CJK drag label a double-width-aware ghost" do
    s = b13m_window
    begin
      label = "日本語.txt" # 7 codepoints, 10 columns
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.drag_mode = :transfer; source.draggable = true
      source.on(Crysterm::Event::DragStart) { |e| e.data["text/plain"] = label }

      b13m_down s, 2, 1, ::Tput::Mouse::Button::Left
      b13m_move s, 10, 5 # promotes to a drag; the transfer source floats a ghost

      ghost = s.children.find { |c| !c.same?(source) }
      ghost.should_not be_nil
      # Column-based width: Unicode.display_width(label) + 2 == 12. The
      # pre-fix codepoint sizing (`label.size + 2` == 9) clipped the label
      # mid-glyph. (The first cut of the fix used `Unicode.width`, which
      # measures a single grapheme — 2 — and shrank the ghost to the 6-column
      # floor; `display_width` is the whole-string sum.)
      ::Crysterm::Unicode.display_width(label).should eq 10
      ghost.not_nil!.awidth.should eq 12

      s._drag_key_handled(b13m_key('\0', ::Tput::Key::Escape)) # clean up the gesture
    ensure
      s.destroy
    end
  end
end
