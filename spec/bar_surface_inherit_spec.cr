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

# The backgrounds across row *y*, one per column.
private def row_bgs(s, y) : Array(Int32)
  (0...s.width).map { |x| cell_bg(s, x, y) }
end

# A main window with three menus and a label floated over the bar's right end
# (an application's key hint), a status bar with a normal field and two
# permanent ones, and a central box.
private def chrome(s) : Widget::MainWindow
  main = Widget::MainWindow.new parent: s
  bar = main.menu_bar
  bar.add_menu "&File"
  bar.add_menu "&Edit"
  bar.add_menu "&View"
  bar.append Widget::Label.new("Menu = F10 ", top: 0, right: 0, height: 1)
  sb = main.status_bar
  sb.add_widget Widget::Label.new(text: "notes.md")
  sb.add_permanent_widget Widget::Label.new(text: "Ln 1", width: 10)
  sb.add_permanent_widget Widget::ToolButton.new(text: "INS", width: 5)
  main.central_widget = Widget::Box.new
  main
end

# The built-in themes: the two fixed palettes and the terminal theme with
# nothing probed (no surface rule at all, the bars still their own color).
private def built_in_themes
  {
    Crysterm::CSS::Theme.dark,
    Crysterm::CSS::Theme.light,
    Crysterm::CSS::Theme.from_terminal(nil, nil, Array(Int32?).new(16, nil)),
  }
end

# A bar is one surface: the theme's `Box` surface rule must not paint the
# titles, fields and labels on it their own blocks, and the message a status
# bar paints itself must come up in the color of the field it replaced. The
# theme says `MenuBar Box, ToolBar Box, StatusBar Box { background-color:
# inherit }`, so this also covers `inherit` on a background.
describe "Bar surface" do
  built_in_themes.each do |theme|
    it "paints the #{theme.name} menu bar one color under the titles, across the gap and under a floated label" do
      s = headless_screen(60, 8)
      with_theme(theme) do
        main = chrome s
        s.repaint
        bar_bg = main.menu_bar.style.bg
        bar_bg.should_not be_nil
        row_bgs(s, 0).uniq.should eq [bar_bg]
        # The bar's own color, not the central area's surface.
        cell_bg(s, 0, 3).should_not eq bar_bg
      end
    end

    it "paints the #{theme.name} status bar one color under its fields, across the gap and while a message shows" do
      s = headless_screen(60, 8)
      with_theme(theme) do
        main = chrome s
        s.repaint
        bar_bg = main.status_bar.style.bg
        bar_bg.should_not be_nil
        row_text(s, 7).should start_with "notes.md"
        row_bgs(s, 7).uniq.should eq [bar_bg]
        main.status_bar.show_message " Saved", 3.seconds
        s.repaint
        row_text(s, 7).should start_with " Saved"
        row_bgs(s, 7).uniq.should eq [bar_bg]
      end
    end
  end

  it "keeps a state highlight over the inherited bar color" do
    s = headless_screen(60, 8)
    with_theme(Crysterm::CSS::Theme.dark) do
      main = chrome s
      bar = main.menu_bar
      bar.focus
      s.repaint
      # The focused bar lights its current title (`Box:selected`, the accent);
      # the rest of the row stays the bar's.
      cell_bg(s, 1, 0).should eq 0x89b4fa
      cell_bg(s, 20, 0).should eq bar.style.bg
    end
  end

  it "copies the parent's background where a rule says `inherit`, unless something set one since" do
    s = headless_screen(20, 4)
    with_theme(nil) do
      s.stylesheet = <<-CSS
        .host { background-color: #112233; }
        .host Box { background-color: inherit; }
        .host .own { background-color: #445566; }
        CSS
      host = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 4
      host.add_css_class "host"
      plain = Widget::Box.new parent: host, left: 0, top: 0, width: 5, height: 1
      own = Widget::Box.new parent: host, left: 5, top: 0, width: 5, height: 1
      own.add_css_class "own"
      Widget::Box.new parent: host, left: 10, top: 0, width: 5, height: 1, style: Style.new(bg: 0x778899)
      s.repaint
      plain.style.bg_inherit?.should be_true
      cell_bg(s, 0, 0).should eq 0x112233
      # A more specific rule, and an inline style, each win over the request.
      cell_bg(s, 5, 0).should eq 0x445566
      cell_bg(s, 10, 0).should eq 0x778899
      # The host's remainder is its own color: nothing bled the other way.
      cell_bg(s, 0, 2).should eq 0x112233
    end
  end
end
