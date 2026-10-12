require "./spec_helper"

include Crysterm

# A presence-only attribute selector (`[checked]`, `[flat]`) followed by a
# combinator or a closing paren. The `html5` engine's compiler steps past the
# token after such a `]`, so these selectors are handed to it in
# `Selectors.engine_form` (`[checked]/**/`), which keeps that token.

# A box holding a check box and, after it, a label — siblings in that order.
private def checkbox_and_label(sheet : String) : Tuple(Window, Widget::CheckBox, Widget::Label)
  s = headless_screen(40, 10)
  box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 4
  chk = Widget::CheckBox.new parent: box, top: 0, left: 0, width: 8, height: 1, content: "c"
  lbl = Widget::Label.new parent: box, top: 1, left: 0, width: 10, height: 1, text: "l"
  s.stylesheet = sheet
  s.apply_stylesheet
  {s, chk, lbl}
end

describe "Crysterm::CSS::Selectors.engine_form" do
  it "follows a presence-only attribute selector with an empty comment" do
    Crysterm::CSS::Selectors.engine_form(".CheckBox[checked] ~ .Label").should eq ".CheckBox[checked]/**/ ~ .Label"
    Crysterm::CSS::Selectors.engine_form(".Box:not([checked])").should eq ".Box:not([checked]/**/)"
    Crysterm::CSS::Selectors.engine_form(".CheckBox[checked]").should eq ".CheckBox[checked]/**/"
  end

  it "leaves valued attribute selectors and selectors without one as they are" do
    Crysterm::CSS::Selectors.engine_form(%(.A[x="1"] ~ .B)).should eq %(.A[x="1"] ~ .B)
    Crysterm::CSS::Selectors.engine_form(%(.A[x~="]"] .B)).should eq %(.A[x~="]"] .B)
    Crysterm::CSS::Selectors.engine_form(".A > .B").should eq ".A > .B"
  end
end

describe "CSS presence-only attribute selectors before a combinator" do
  it "matches `CheckBox[checked] ~ Label` on the label after a checked box only" do
    s, chk, lbl = checkbox_and_label "CheckBox[checked] ~ Label { font-style: italic; }"
    lbl.styles.normal.italic?.should be_false
    chk.checked = true
    s.apply_stylesheet
    lbl.styles.normal.italic?.should be_true
    chk.checked = false
    s.apply_stylesheet
    lbl.styles.normal.italic?.should be_false
  end

  it "matches the `:checked` spelling, lowered to `[checked]`, before `+`" do
    s, chk, lbl = checkbox_and_label "CheckBox:checked + Label { color: #ff0000; }"
    lbl.styles.normal.fg.should_not eq 0xff0000
    chk.checked = true
    s.apply_stylesheet
    lbl.styles.normal.fg.should eq 0xff0000
  end

  it "compiles `:not([checked])`" do
    s, chk, lbl = checkbox_and_label "CheckBox:not([checked]) ~ Label { font-style: italic; }"
    lbl.styles.normal.italic?.should be_true
    chk.checked = true
    s.apply_stylesheet
    lbl.styles.normal.italic?.should be_false
  end

  it "keeps the child and descendant combinators after `[flat]`" do
    s = headless_screen(40, 10)
    flat = Widget::GroupBox.new parent: s, flat: true, top: 0, left: 0, width: 20, height: 5
    framed = Widget::GroupBox.new parent: s, top: 5, left: 0, width: 20, height: 5
    inner = Widget::Box.new parent: flat, top: 0, left: 0, width: 10, height: 2
    direct = Widget::Label.new parent: flat, top: 2, left: 0, width: 5, height: 1, text: "d"
    nested = Widget::Label.new parent: inner, top: 0, left: 0, width: 5, height: 1, text: "n"
    other = Widget::Label.new parent: framed, top: 0, left: 0, width: 5, height: 1, text: "o"
    s.stylesheet = <<-CSS
      GroupBox[flat] > Label { color: #00ff00; }
      GroupBox[flat] Label { font-style: italic; }
      CSS
    s.apply_stylesheet
    direct.styles.normal.fg.should eq 0x00ff00
    nested.styles.normal.fg.should_not eq 0x00ff00
    direct.styles.normal.italic?.should be_true
    nested.styles.normal.italic?.should be_true
    other.styles.normal.italic?.should be_false
  end
end
