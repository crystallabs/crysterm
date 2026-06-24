require "./spec_helper"

include Crysterm

# Regression guard for the real Qt theme corpus shipped in `data/css/*.qss`.
#
# These are large, hand-written Qt stylesheets (Breeze, QDarkStyle, qtmodern)
# full of vocabulary Crysterm only partially supports — `url()`, `border-radius`,
# unmapped `::sub-controls`, gradients, `subcontrol-origin`, etc. The contract
# (see `CSS::Qss` / the tolerant parser) is that none of it is ever *fatal*:
# unknown selectors match nothing, unknown properties are skipped. This spec
# proves that end-to-end — every corpus file must translate, parse, and drive a
# real render of a representative widget tree without raising — so future
# `.qss`-support work can't silently regress the "never aborts" guarantee.

private CORPUS = Dir.glob(File.join(__DIR__, "..", "data", "css", "*.qss")).sort

# A small but varied widget tree: each widget exercises a different family of
# corpus selectors (buttons, check/radio, sliders/bars, lists/tables, combos,
# containers, text). Built once per file so the cascade runs against every rule.
private def build_widget_zoo(screen) : Nil
  Widget::Box.new parent: screen, top: 0, left: 0, width: 20, height: 6
  Widget::Button.new parent: screen, top: 0, left: 22, width: 10, height: 3, content: "ok"
  Widget::CheckBox.new parent: screen, top: 3, left: 22, content: "c"
  Widget::RadioButton.new parent: screen, top: 4, left: 22, content: "r"
  Widget::Slider.new parent: screen, top: 6, left: 0, width: 20, height: 1
  Widget::ProgressBar.new parent: screen, top: 7, left: 0, width: 20, height: 1
  Widget::List.new parent: screen, top: 8, left: 0, width: 20, height: 4, items: ["a", "b", "c"]
  Widget::ComboBox.new parent: screen, top: 13, left: 0, width: 20, height: 1
  Widget::Table.new parent: screen, top: 14, left: 0, width: 24, rows: [["h1", "h2"], ["1", "2"]]
  Widget::Label.new parent: screen, top: 0, left: 34, content: "x"
end

describe "Qt `.qss` corpus (data/css)" do
  it "ships a non-empty corpus" do
    CORPUS.should_not be_empty
  end

  CORPUS.each do |path|
    name = File.basename(path)

    describe name do
      it "translates and parses without raising, yielding rules" do
        sheet = Crysterm::CSS::Stylesheet.from_file(path)
        sheet.rules.size.should be > 0
      end

      it "drives a real render of a representative widget tree without raising" do
        screen = Crysterm::Screen.new(
          input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
          width: 80, height: 24)
        screen.auto_reload_stylesheet = false
        build_widget_zoo screen
        screen.stylesheet = Crysterm::CSS::Stylesheet.from_file(path)
        screen._render # cascade + cell-buffer fill; must not raise
      end
    end
  end
end
