require "./spec_helper"

include Crysterm

# A disabled action's row in a menu bar's menu, driven as a terminal drives
# it: drawn in the disabled look though its label carries a mnemonic (inline
# underline tags), and clicked to no effect without the highlight on it
# outliving the menu — Qt's `QMenu::hideEvent` leaves no current action, so
# the menu reopens as it first opened.

private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

# A click at (*x*, *y*), the pointer arriving first as a terminal reports it.
private def pointer_click(s, x, y)
  mouse_move s, x, y
  mouse_down s, x, y
  mouse_up s, x, y
  s.repaint
end

# A bar with a File menu of Open, a disabled Previous File and Quit, all
# with mnemonics; the bar's File title is at (1, 0).
private def file_menu(s)
  bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: 60, height: 1
  file = bar.add_menu "&File"
  file.add_action("&Open") { }
  previous = Action.new "&Previous File"
  previous.enabled = false
  file << previous
  file.add_action("&Quit") { }
  s.repaint
  {file, previous}
end

# The row whose label, tags left out, includes *text*.
private def row(file, text)
  file.item_boxes.find! { |b| b.content.gsub(/\{[^}]*\}/, "").includes? text }
end

# The distinct foregrounds of *box*'s first ten cells (its label).
private def label_fgs(s, box)
  (box.aleft...box.aleft + 10).map { |x| cell_fg(s, x, box.atop) }.uniq!
end

describe "Menu disabled state" do
  {Crysterm::CSS::Theme.dark, Crysterm::CSS::Theme.from_terminal(nil, nil, [] of Int32?), Crysterm::CSS::Theme.builtin("breeze-dark").not_nil!}.each do |theme|
    it "draws a disabled entry with a mnemonic wholly in the #{theme.name} theme's disabled color" do
      s = headless_screen(60, 20)
      with_theme(theme) do
        file, _ = file_menu s
        pointer_click s, 1, 0
        file.visible?.should be_true
        enabled = label_fgs(s, row(file, "Open"))
        disabled = label_fgs(s, row(file, "Previous"))
        enabled.size.should eq 1
        disabled.size.should eq 1
        disabled.should_not eq enabled
        label_fgs(s, row(file, "Quit")).should eq enabled
      end
    end
  end

  {"Escape", "a click on its title", "a click outside"}.each do |how|
    it "reopens with no row highlighted after a disabled entry was clicked and the menu closed by #{how}" do
      s = headless_screen(60, 20)
      with_theme(Crysterm::CSS::Theme.dark) do
        file, previous = file_menu s
        fired = false
        previous.on(Event::Triggered) { fired = true }
        pointer_click s, 1, 0
        box = row(file, "Previous")
        plain_bg = cell_bg(s, box.aleft + 1, box.atop)
        pointer_click s, box.aleft + 2, box.atop
        fired.should be_false
        file.visible?.should be_true
        file.selected_action.should be previous
        cell_bg(s, box.aleft + 1, box.atop).should_not eq plain_bg

        case how
        when "Escape"               then s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::Escape)
        when "a click on its title" then pointer_click s, 1, 0
        else                             pointer_click s, 50, 15
        end
        s.repaint
        file.visible?.should be_false
        file.selected_action.try(&.text).should eq "&Open"

        pointer_click s, 1, 0
        file.visible?.should be_true
        cell_bg(s, box.aleft + 1, box.atop).should eq plain_bg
        # Enter reveals the highlight on the first entry, as on a first open,
        # not on the disabled one clicked before.
        s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::Enter)
        s.repaint
        file.selected_action.try(&.text).should eq "&Open"
        cell_bg(s, box.aleft + 1, box.atop).should eq plain_bg
      end
    end
  end

  it "carries a line's start attr onto the default a parent substitutes, keeping what inline SGR changed" do
    from = Attr.pack(0, Attr.pack_color(0x101010), Attr.pack_color(0x202020))
    to = Attr.pack(Attr::BOLD, Attr.pack_color(0x303030), Attr.pack_color(0x404040))
    Attr.rebase(from, from, to).should eq to
    underlined = Attr.pack(Attr::UNDERLINE, Attr.pack_color(0x101010), Attr.pack_color(0x505050))
    Attr.rebase(underlined, from, to).should eq Attr.pack(Attr::UNDERLINE, Attr.pack_color(0x303030), Attr.pack_color(0x505050))
  end
end
