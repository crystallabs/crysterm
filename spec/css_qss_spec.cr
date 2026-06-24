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

    it "leaves ids, classes, combinators and pseudo-elements intact" do
      Crysterm::CSS::Qss.to_css("QToolButton#foo, QPushButton.bar { }")
        .should eq "ToolButton#foo, Button.bar { }"
      Crysterm::CSS::Qss.to_css("QCheckBox::indicator:checked { }")
        .should eq "CheckBox::indicator:checked { }"
    end

    it "passes through Qt selectors with no Crysterm analog (they just match nothing)" do
      Crysterm::CSS::Qss.to_css("QColumnView { }").should eq "ColumnView { }"
    end

    it "does not touch property names or values" do
      Crysterm::CSS::Qss.to_css("QFrame { qproperty-x: 1; color: #ccc; }")
        .should eq "Box { qproperty-x: 1; color: #ccc; }"
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
