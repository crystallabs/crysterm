require "./spec_helper"

include Crysterm

# GLYPHS.md phase 2: the CSS `glyph` property family (`glyph`, per-tier
# longhands, `glyph-open`/`glyph-close`), sub-control addressing
# (`CheckBox::indicator:checked`, `ComboBox::drop-down`, `Slider::handle`,
# `Menu::separator`, …), and the composed/measured markers that replace the
# fixed 3-cell `[x]` slot.

private def gc_screen(width = 80, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

private def gc_row(s, y, x0, len)
  (x0...x0 + len).map { |x| s.lines[y][x].char }.join
end

private def apply(style, prop, value)
  Crysterm::CSS::Properties.apply(style, prop, value)
end

describe "CSS glyph value parsing (Properties.parse_char)" do
  it "accepts a quoted character" do
    st = Style.new
    apply st, "glyph", %("▾")
    st.glyph.should eq '▾'
  end

  it "accepts a bare character" do
    st = Style.new
    apply st, "glyph", "▾"
    st.glyph.should eq '▾'
  end

  it "accepts decimal and hex code points (Qt convention)" do
    st = Style.new
    apply st, "glyph", "9662"
    st.glyph.should eq '▾'
    apply st, "glyph", "0x25CF"
    st.glyph.should eq '●'
  end

  it "keeps a quoted digit a literal, not a code point" do
    st = Style.new
    apply st, "glyph", %("9")
    st.glyph.should eq '9'
  end

  it "stores the NONE sentinel for `none`" do
    st = Style.new
    apply st, "glyph", "none"
    st.glyph.should eq Glyphs::NONE
  end

  it "drops a blank value (collapsed var()) and an out-of-range code point" do
    st = Style.new
    apply st, "glyph", "▾"
    apply st, "glyph", ""
    st.glyph.should eq '▾' # unchanged
    apply st, "glyph", "99999999999"
    st.glyph.should eq '▾' # unchanged
  end
end

describe "Style#glyph_for tier resolution" do
  it "resolves the tier longhand, falling down tiers, then the universal glyph" do
    st = Style.new
    st.glyph = '*'
    st.glyph_for(Glyphs::Tier::Extended).should eq '*'
    st.glyph_for(Glyphs::Tier::Ascii).should eq '*'

    st.glyph_ascii = 'v'
    st.glyph_unicode = '▾'
    st.glyph_for(Glyphs::Tier::Extended).should eq '▾' # falls down to unicode
    st.glyph_for(Glyphs::Tier::Unicode).should eq '▾'
    st.glyph_for(Glyphs::Tier::Ascii).should eq 'v'

    st.glyph_extended = '⯆'
    st.glyph_for(Glyphs::Tier::Extended).should eq '⯆'
  end

  it "answers nil when nothing is specified" do
    Style.new.glyph_for(Glyphs::Tier::Unicode).should be_nil
  end
end

describe "CSS fill-char family spellings" do
  it "sets fill-char and percent-char" do
    st = Style.new
    apply st, "fill-char", %("▒")
    st.fill_char.should eq '▒'
    st.specified?(:fill_char).should be_true
    apply st, "percent-char", %("%")
    st.percent_char.should eq '%'
  end

  it "drops `none` for a fill char (a cell is always painted)" do
    st = Style.new
    apply st, "fill-char", %("▒")
    apply st, "fill-char", "none"
    st.fill_char.should eq '▒' # unchanged
  end
end

describe "CheckBox::indicator glyph theming" do
  it "restyles the delimiters and per-state mark" do
    s = gc_screen
    cb = Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept"
    s.stylesheet = <<-CSS
      CheckBox::indicator { glyph-open: "<"; glyph-close: ">"; glyph: "."; }
      CheckBox::indicator:checked { glyph: "*"; }
      CSS
    s.apply_stylesheet
    s._render
    gc_row(s, 0, 0, 9).should eq "<.> Accep"

    cb.check
    s._render
    # The `[checked]`-gated rule outranks the stateless mark.
    gc_row(s, 0, 0, 9).should eq "<*> Accep"
  end

  it "composes a single-glyph marker when the delimiters are none-d away" do
    s = gc_screen
    cb = Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept", checked: true
    s.stylesheet = <<-CSS
      CheckBox::indicator { glyph-open: none; glyph-close: none; glyph: "●"; }
      CSS
    s.apply_stylesheet
    s._render
    # Marker shrinks from 3 cells to 1; the label follows after the gap.
    gc_row(s, 0, 0, 8).should eq "● Accept"
    cb.checked?.should be_true
  end

  it "keeps the marker click hit-test in step with the measured width" do
    s = gc_screen
    cb = Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept"
    s.stylesheet = %(CheckBox::indicator { glyph-open: none; glyph-close: none; glyph: "●"; })
    s.apply_stylesheet
    s._render
    # Column 1 is now label gap, not marker: a click there must not toggle.
    s.dispatch_mouse(::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, cb.aleft + 1, cb.atop, source: :test))
    cb.checked?.should be_false
    # The 1-cell marker itself still toggles.
    s.dispatch_mouse(::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, cb.aleft, cb.atop, source: :test))
    cb.checked?.should be_true
  end

  it "leaves the unstyled marker byte-identical with the classic [x]" do
    s = gc_screen
    Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept", checked: true
    s._render
    gc_row(s, 0, 0, 10).should eq "[x] Accept"
  end
end

describe "RadioButton::indicator glyph theming" do
  it "restyles the checked mark via :checked" do
    s = gc_screen
    rb = Widget::RadioButton.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "One"
    s.stylesheet = %(RadioButton::indicator:checked { glyph: "o"; })
    s.apply_stylesheet
    s._render
    gc_row(s, 0, 0, 7).should eq "( ) One" # unchecked mark untouched
    rb.check
    s._render
    gc_row(s, 0, 0, 7).should eq "(o) One"
  end
end

describe "ComboBox::drop-down glyph" do
  it "restyles the arrow and collapses it for `none`" do
    s = gc_screen
    Widget::ComboBox.new ["Apple"], parent: s, top: 0, left: 0, width: 12, height: 1
    s.stylesheet = %(ComboBox::drop-down { glyph: "↓"; })
    s.apply_stylesheet
    s._render
    gc_row(s, 0, 0, 7).should eq "Apple ↓"

    s.stylesheet = %(ComboBox::drop-down { glyph: none; })
    s.apply_stylesheet
    s._render
    gc_row(s, 0, 0, 7).should eq "Apple  "
  end
end

describe "Slider::handle / cell-role validation" do
  it "restyles the handle through the ::handle alias of ::indicator" do
    s = gc_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 11, height: 1, value: 0
    s.stylesheet = <<-CSS
      Slider::handle { glyph: "◆"; }
      Slider { glyph: "x"; }
      CSS
    s.apply_stylesheet
    s._render
    # Handle at the low end; the widget-wide `glyph` must NOT bleed into the
    # track (only an explicitly-set sub-style answers for a part).
    s.lines[0][sl.aleft].char.should eq '◆'
    s.lines[0][sl.aleft + 5].char.should eq '─'
  end

  it "rejects a wide character on a cell role (falls back to the registry)" do
    s = gc_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 11, height: 1, value: 0
    s.stylesheet = %(Slider::handle { glyph: "🚀"; })
    s.apply_stylesheet
    s._render
    s.lines[0][sl.aleft].char.should eq '█' # registry default, not the emoji
  end
end

describe "Menu glyphs and measured columns" do
  it "drops the check gutter when no item is checkable" do
    s = gc_screen
    menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 12, height: 4
    menu.add "Open"
    s._render
    # Label starts flush at the content edge (border + theme padding = 2).
    gc_row(s, 1, menu.aleft + 2, 5).should eq "Open " # no 4-cell gutter
  end

  it "reserves a measured check column when any item is checkable" do
    s = gc_screen
    menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 14, height: 5
    a = menu.add "Wrap"
    a.checkable = true
    a.checked = true
    menu.add "Open"
    s._render
    gc_row(s, 1, menu.aleft + 2, 8).should eq "[x] Wrap"
    gc_row(s, 2, menu.aleft + 2, 8).should eq "    Open"
  end

  it "restyles the separator rule via Menu::separator { glyph }" do
    s = gc_screen
    menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 12, height: 5
    menu.add "One"
    menu.add_separator
    menu.add "Two"
    s.stylesheet = %(Menu::separator { glyph: "="; })
    s.apply_stylesheet
    s._render
    sep_y = menu.atop + 2
    gc_row(s, sep_y, menu.aleft + 1, 10).includes?("====").should be_true
  end

  it "restyles the submenu arrow via Menu::indicator, including none" do
    s = gc_screen
    menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 14, height: 4
    menu.add_menu "More", [Action.new("Child")]
    s.stylesheet = %(Menu::indicator { glyph: "»"; })
    s.apply_stylesheet
    s._render
    row = gc_row(s, menu.atop + 1, menu.aleft + 1, 12)
    row.includes?("More").should be_true
    row.includes?("»").should be_true

    s.stylesheet = %(Menu::indicator { glyph: none; })
    s.apply_stylesheet
    s._render
    gc_row(s, menu.atop + 1, menu.aleft + 1, 12).includes?("▶").should be_false
  end
end
