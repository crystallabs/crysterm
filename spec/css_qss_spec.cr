require "./spec_helper"

include Crysterm

# `.qss` (Qt Style Sheet) -> Crysterm CSS selector translation: strip the `Q`
# type-selector prefix, then apply the `RENAMES` map; everything else is left
# verbatim for the (tolerant) parser.
describe Crysterm::CSS::Qss do
  describe ".to_css" do
    it "strips the Q prefix from identically-named selectors" do
      Crysterm::CSS::Qss.to_css("QGroupBox { color: red; }")
        .should eq "GroupBox { color: red; }"
      Crysterm::CSS::Qss.to_css("QWidget { color: red; }")
        .should eq "Widget { color: red; }"
    end

    it "renames Qt selectors that Crysterm spells differently" do
      Crysterm::CSS::Qss.to_css("QPushButton { }").should eq "Button { }"
      Crysterm::CSS::Qss.to_css("QLineEdit { }").should eq "TextBox { }"
      Crysterm::CSS::Qss.to_css("QTreeView { }").should eq "Tree { }"
      Crysterm::CSS::Qss.to_css("QHeaderView { }").should eq "Header { }"
    end

    it "transforms every type selector in a compound/descendant selector" do
      Crysterm::CSS::Qss.to_css("QComboBox QAbstractItemView { }")
        .should eq "ComboBox List { }"
    end

    it "leaves ids, classes and combinators intact" do
      Crysterm::CSS::Qss.to_css("QToolButton#foo, QPushButton.bar { }")
        .should eq "ToolButton#foo, Button.bar { }"
    end

    it "passes through Qt selectors with no Crysterm analog (they just match nothing)" do
      Crysterm::CSS::Qss.to_css("QColumnView { }").should eq "ColumnView { }"
    end

    it "does not touch property names or values" do
      Crysterm::CSS::Qss.to_css("QFrame { qproperty-x: 1; color: #ccc; }")
        .should eq "Box { qproperty-x: 1; color: #ccc; }"
    end
  end

  describe "sub-elements (::)" do
    it "rewrites a mapped Qt pseudo-element to a Crysterm descendant slot" do
      Crysterm::CSS::Qss.to_css("QProgressBar::chunk { }")
        .should eq "ProgressBar Indicator { }"
      Crysterm::CSS::Qss.to_css("QSlider::handle:hover { }")
        .should eq "Slider Indicator:hover { }"
      Crysterm::CSS::Qss.to_css("QScrollBar::groove { }")
        .should eq "ScrollBar Track { }"
    end

    it "keeps a sub-control's own state pseudo attached (e.g. handle hovered)" do
      Crysterm::CSS::Qss.to_css("QSlider::handle:pressed { }")
        .should eq "Slider Indicator:active { }"
    end

    it "passes QScrollBar sub-controls through for native :: lowering" do
      # `::add-page`/`::up-arrow`/… have no `SUB_ELEMENTS` alias, so qss leaves
      # the `::` for the native parser, which lowers it onto `ScrollBar`'s slot.
      Crysterm::CSS::Qss.to_css("QScrollBar::add-page { color: red; }")
        .should eq "ScrollBar::add-page { color: red; }"
      Crysterm::CSS::Qss.to_css("QScrollBar::up-arrow:hover { }")
        .should eq "ScrollBar::up-arrow:hover { }"
    end

    # KNOWN GAP: Qt's `::indicator:checked` means "indicator *while the parent is
    # checked*", but we don't hoist a parent-state onto the type. `::indicator`
    # and `:checked` are now both lowered by the *native* parser (to the
    # `Indicator` descendant node and `[checked]`), so `Qss.to_css` leaves them
    # verbatim here — and the resulting `CheckBox Indicator[checked]` matches
    # nothing. The plain `QCheckBox:checked` (state on the widget) and
    # `QCheckBox::indicator` (sub-element, no state) forms both work. Tracked in
    # the plan.
    it "composes sub-element + state literally (parent-state-on-subcontrol is a gap)" do
      Crysterm::CSS::Qss.to_css("QCheckBox::indicator:checked { }")
        .should eq "CheckBox::indicator:checked { }"
    end

    it "leaves an unmapped Qt pseudo-element verbatim (matches nothing)" do
      Crysterm::CSS::Qss.to_css("QTabBar::tab { }").should eq "TabWidget::tab { }"
      Crysterm::CSS::Qss.to_css("QComboBox::down-arrow { }")
        .should eq "ComboBox::down-arrow { }"
    end
  end

  describe "state pseudo-classes" do
    it "maps the Qt-specific checkable spellings to complementary boolean attributes" do
      # `:on`/`:off` and `:unchecked` are Qt vocabulary, rewritten here.
      Crysterm::CSS::Qss.to_css("QCheckBox:unchecked { }").should eq "CheckBox[unchecked] { }"
      Crysterm::CSS::Qss.to_css("QPushButton:on { }").should eq "Button[checked] { }"
      Crysterm::CSS::Qss.to_css("QPushButton:off { }").should eq "Button[unchecked] { }"
    end

    it "leaves standard-CSS :checked/:indeterminate/:enabled for the native parser" do
      # These are Selectors-L4 standard and lowered natively by `Stylesheet`
      # (`ATTR_PSEUDOS`) for every stylesheet, so `Qss.to_css` passes them through.
      Crysterm::CSS::Qss.to_css("QCheckBox:checked { }").should eq "CheckBox:checked { }"
      Crysterm::CSS::Qss.to_css("QCheckBox:indeterminate { }").should eq "CheckBox:indeterminate { }"
      Crysterm::CSS::Qss.to_css("QPushButton:enabled { }").should eq "Button:enabled { }"
    end

    it "maps the Qt-specific :pressed to an expressible Crysterm form" do
      Crysterm::CSS::Qss.to_css("QPushButton:pressed { }").should eq "Button:active { }"
    end

    it "maps orientation and :editable to boolean attributes" do
      Crysterm::CSS::Qss.to_css("QScrollBar:horizontal { }").should eq "ScrollBar[horizontal] { }"
      Crysterm::CSS::Qss.to_css("QSlider:vertical { }").should eq "Slider[vertical] { }"
      Crysterm::CSS::Qss.to_css("QComboBox:editable { }").should eq "ComboBox[editable] { }"
    end

    it "leaves states Crysterm already handles untouched" do
      Crysterm::CSS::Qss.to_css("QPushButton:hover { }").should eq "Button:hover { }"
      Crysterm::CSS::Qss.to_css("QPushButton:focus:disabled { }").should eq "Button:focus:disabled { }"
    end

    it "does not bite into longer tokens (e.g. :only-one, :on-prefix)" do
      Crysterm::CSS::Qss.to_css("QTabBar:only-one { }").should eq "TabWidget:only-one { }"
    end
  end

  describe "palette()" do
    it "translates Qt palette roles to theme var(--role) custom properties" do
      Crysterm::CSS::Qss.to_css("Label { color: palette(highlight); }")
        .should eq "Label { color: var(--accent); }"
      Crysterm::CSS::Qss.to_css("Label { background: palette(base); }")
        .should eq "Label { background: var(--surface-dark); }"
    end

    it "leaves an unknown palette role untouched (parser ignores it)" do
      Crysterm::CSS::Qss.to_css("X { color: palette(nonsense); }")
        .should eq "X { color: palette(nonsense); }"
    end
  end

  it "parses a translated stylesheet without aborting on unknown Qt syntax" do
    qss = <<-QSS
      QPushButton { background-color: #222; subcontrol-origin: margin; }
      QCheckBox::indicator { border-image: url(:/x.png); }
      QColumnView { color: pink; }
    QSS
    sheet = Crysterm::CSS::Stylesheet.parse(Crysterm::CSS::Qss.to_css(qss))
    sheet.rules.size.should be > 0
  end
end
