require "./spec_helper"

include Crysterm

# Installs *theme* for the block — the window exists already, so
# `ensure_theme` has run and this assignment is what sets the default
# stylesheet — restoring the previous theme afterwards.
private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

# The widgets a theme's look shows on: a box for the window surface, a menu
# bar, a plain editor and a rich viewer, and a group box.
private def furnish(s) : Nil
  Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 12
  bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: 60, height: 1
  bar.add_menu "&File"
  Widget::PlainTextEdit.new parent: s, top: 2, left: 0, width: 28, height: 6, content: "source"
  Widget::TextBrowser.new parent: s, top: 2, left: 30, width: 28, height: 6, content: "rendered"
  Widget::GroupBox.new parent: s, top: 9, left: 0, width: 20, height: 3
end

# The Qt themes under `data/css` are embedded in the binary and installed
# like the generated themes: the sheet, translated, lies over the generated
# rules in the theme's default stylesheet, with the palette the generated
# rules use derived from the sheet's own window colors.
describe "Theme: the built-in Qt stylesheets" do
  it "embeds the five sheets by file name, read at compile time" do
    Crysterm::CSS::Theme::BUILTIN_STYLESHEETS.keys.should eq %w[breeze-dark breeze-light qdarkstyle-dark qdarkstyle-light qtmodern-dark]
    Crysterm::CSS::Theme::BUILTIN_STYLESHEETS.each do |name, source|
      source.should eq File.read(File.join(__DIR__, "..", "data", "css", "#{name}.qss"))
    end
  end

  it "names each sheet as a colors.theme choice, read with dashes or as a member" do
    Crysterm::CSS::Theme::Choice::BreezeDark.builtin_stylesheet.should eq "breeze-dark"
    Crysterm::CSS::Theme::Choice::QdarkstyleLight.builtin_stylesheet.should eq "qdarkstyle-light"
    Crysterm::CSS::Theme::Choice::Dark.builtin_stylesheet.should be_nil
    Crysterm::CSS::Theme::Choice.parse("breeze-dark").should eq Crysterm::CSS::Theme::Choice::BreezeDark
    Crysterm::CSS::Theme::Choice.parse("qtmodern_dark").should eq Crysterm::CSS::Theme::Choice::QtmodernDark
    Crysterm::CSS::Theme::BUILTIN_STYLESHEETS.each_key do |name|
      Crysterm::CSS::Theme::Choice.parse(name).builtin_stylesheet.should eq name
    end
  end

  it "makes a theme from a sheet once, in the sheet's own window colors" do
    breeze = Crysterm::CSS::Theme.builtin("breeze-dark").not_nil!
    breeze.name.should eq "breeze-dark"
    breeze.dark?.should be_true
    breeze.primaries["surface"].should eq 0x31363b # QWidget { background-color }
    breeze.primaries["text"].should eq 0xeff0f1    # QWidget { color }
    breeze.primaries["accent"].should eq 0x3daee9  # QWidget { selection-background-color }
    breeze.overlay.not_nil!.should contain "PlainTextEdit"
    breeze.overlay.not_nil!.should_not contain "QPlainTextEdit"
    Crysterm::CSS::Theme.builtin("breeze-dark").should eq breeze
    Crysterm::CSS::Theme.builtin("breeze-dark").not_nil!.stylesheet.should be Crysterm::CSS::Theme.builtin("breeze-dark").not_nil!.stylesheet
    Crysterm::CSS::Theme.builtin("no-such").should be_nil

    light = Crysterm::CSS::Theme.builtin("breeze-light").not_nil!
    light.dark?.should be_false
    light.primaries["surface"].should eq 0xeff0f1
    # A sheet with no QWidget rule keeps the generated palette its name says.
    modern = Crysterm::CSS::Theme.builtin("qtmodern-dark").not_nil!
    modern.dark?.should be_true
    modern.primaries.should eq Crysterm::CSS::Theme.dark.primaries
  end

  it "resolves a built-in choice to its theme, as the config is resolved" do
    s = headless_screen(60, 12)
    Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::BreezeDark, s).should eq Crysterm::CSS::Theme.builtin("breeze-dark")
    Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::Dark, s).should eq Crysterm::CSS::Theme.dark
    Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::None, s).should be_nil
    Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::Terminal, s).try(&.name).should eq "terminal"
  end

  it "paints the window in the sheet's colors, its own rules over the generated ones" do
    s = headless_screen(60, 12)
    with_theme(Crysterm::CSS::Theme.builtin("breeze-dark")) do
      furnish s
      s.repaint
      cell_bg(s, 59, 11).should eq 0x31363b # the surface: QWidget's background
      cell_bg(s, 30, 0).should eq 0x31363b  # QMenuBar's background
      cell_fg(s, 30, 0).should eq 0xeff0f1  # QMenuBar's text
      # The bar's current title is a box the generated `Box:selected` paints,
      # in the accent derived from the sheet's selection color.
      cell_bg(s, 1, 0).should eq 0x3daee9
      cell_bg(s, 2, 4).should eq 0x1d2023  # QPlainTextEdit's, over the generated --surface-dark
      cell_bg(s, 32, 4).should eq 0x1d2023 # QTextEdit's, for the TextBrowser
    end
  end

  it "fills what a sheet says in Qt's palette roles from the derived palette" do
    s = headless_screen(60, 12)
    modern = Crysterm::CSS::Theme.builtin("qtmodern-dark").not_nil!
    with_theme(modern) do
      furnish s
      s.repaint
      # QGroupBox { background-color: palette(alternate-base) } → --surface-light
      cell_bg(s, 10, 10).should eq modern.shades("surface")[:light]
      # The surface itself is the generated dark one: the sheet never paints QWidget.
      cell_bg(s, 59, 11).should eq Crysterm::CSS::Theme.dark.primaries["surface"]
    end
  end

  it "keeps an author stylesheet over a built-in Qt theme" do
    s = headless_screen(60, 12)
    with_theme(Crysterm::CSS::Theme.builtin("qdarkstyle-light")) do
      furnish s
      s.stylesheet = "TextBrowser { background-color: #123456; }"
      s.repaint
      cell_bg(s, 32, 4).should eq 0x123456
      cell_bg(s, 59, 11).should eq 0xfafafa # QDarkStyle light's QWidget background
    end
  end
end
