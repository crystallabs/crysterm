require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 findings A15, A17 and A19 — cached popup widgets
# and their lifecycle.
#
#  A15: ComboBox/DateEdit/Completer built their drop-down once (`@popup ||=`)
#     on the construction-time window; after a cross-window reparent the popup
#     stayed stranded on the OLD window while placement and the dismiss grab
#     used the new one.
#  A17: Tab-away from an open ComboBox — the editable Blur handler's `close`
#     unconditionally refocused the combo (re-entering the focus machinery
#     mid-blur), and a non-editable combo never closed its popup on focus loss.
#  A19: Completer never tore down on its LineEdit's destroy — the popup leaked
#     as a permanent window child.

describe "BUGS13 A15: cached popups migrate on cross-window reparent" do
  it "rebuilds the ComboBox popup on the new window" do
    w1 = headless_screen(60, 20)
    w2 = headless_screen(60, 20)
    combo = Widget::ComboBox.new parent: w1, options: %w[a b c],
      top: 0, left: 0, width: 12, height: 1
    w1.repaint

    combo.show_popup
    pop1 = combo.@popup.not_nil!
    pop1.window?.should eq w1
    combo.hide_popup

    w2.append combo
    w2.repaint

    combo.show_popup
    pop2 = combo.@popup.not_nil!
    pop2.same?(pop1).should be_false # stale popup dropped, not reused
    pop2.window?.should eq w2        # rendered on the combo's current window
    combo.hide_popup
  end

  it "rebuilds the DateEdit calendar on the new window" do
    w1 = headless_screen(60, 20)
    w2 = headless_screen(60, 20)
    de = Widget::DateEdit.new parent: w1, top: 0, left: 0, width: 12, height: 1
    w1.repaint

    de.show_popup
    pop1 = de.@popup.not_nil!
    pop1.window?.should eq w1
    de.hide_popup

    w2.append de
    w2.repaint

    de.show_popup
    pop2 = de.@popup.not_nil!
    pop2.same?(pop1).should be_false
    pop2.window?.should eq w2
    de.hide_popup
  end

  it "rebuilds the Completer popup on the box's new window" do
    w1 = headless_screen(60, 20)
    w2 = headless_screen(60, 20)
    box = Widget::LineEdit.new parent: w1, top: 0, left: 0, width: 20, height: 1
    comp = Completer.new %w[apple apricot banana]
    comp.attach box
    w1.repaint

    box.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Down) # opens
    comp.open?.should be_true
    pop1 = comp.@popup.not_nil!
    pop1.window?.should eq w1
    box.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape) # closes

    w2.append box
    w2.repaint

    box.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
    comp.open?.should be_true
    pop2 = comp.@popup.not_nil!
    pop2.same?(pop1).should be_false
    pop2.window?.should eq w2
  end
end

describe "BUGS13 A17: Tab-away from an open ComboBox" do
  it "editable: closes without stealing focus back" do
    s = headless_screen(60, 20)
    combo = Widget::ComboBox.new parent: s, options: %w[a b c], editable: true,
      top: 0, left: 0, width: 12, height: 1
    other = Widget::Box.new parent: s, input: true, top: 5, left: 0, width: 5, height: 1
    s.repaint

    combo.focus
    combo.show_popup
    combo.open?.should be_true

    other.focus

    combo.open?.should be_false # popup dismissed on blur
    # `close` must not refocus the combo mid-blur — focus would bounce back
    # and the target would never keep it.
    s.focused.should eq other
  end

  it "non-editable: dismisses the popup (and grab) when focus leaves the pair" do
    s = headless_screen(60, 20)
    combo = Widget::ComboBox.new parent: s, options: %w[a b c],
      top: 0, left: 0, width: 12, height: 1
    other = Widget::Box.new parent: s, input: true, top: 5, left: 0, width: 5, height: 1
    s.repaint

    combo.focus
    combo.show_popup # focuses the popup
    combo.open?.should be_true

    other.focus

    # Focus loss must close the popup — otherwise it stays open with a live
    # modal mouse grab until an outside click.
    combo.open?.should be_false
    s.focused.should eq other
  end
end

describe "BUGS13 A19: Completer tears down when its LineEdit is destroyed" do
  it "detaches and destroys the popup on the box's Destroy" do
    s = headless_screen(60, 20)
    box = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
    comp = Completer.new %w[apple apricot banana]
    comp.attach box
    s.repaint

    box.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
    comp.open?.should be_true
    pop = comp.@popup.not_nil!
    s.children.includes?(pop).should be_true

    box.destroy

    # The popup must not remain a window child forever, nor the completer keep
    # referencing the dead widget.
    comp.open?.should be_false
    comp.@popup.should be_nil
    comp.@widget.should be_nil
    s.children.includes?(pop).should be_false
  end
end
