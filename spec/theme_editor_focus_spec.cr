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

# The built-in themes, each with its own palette shades.
private def built_in_themes
  {Crysterm::CSS::Theme.dark, Crysterm::CSS::Theme.light}
end

# The theme's generated rules lighten a one-line field while it has the
# focus, as a form's active field conventionally does; the multi-line
# editor keeps one background in either state, as Qt's `QPlainTextEdit`
# keeps its base color and changes only its focus frame — an editor pane
# that changed shade with the focus read as dimmed whenever the user worked
# in another pane, next to a viewer that did not.
describe "Theme: the editor's background and the focus" do
  built_in_themes.each do |theme|
    it "paints the #{theme.name} editor the same focused and unfocused" do
      s = headless_screen(40, 8)
      with_theme(theme) do
        editor = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 6, content: "text"
        other = Widget::PlainTextEdit.new parent: s, top: 0, left: 20, width: 20, height: 6, content: "other"
        editor.focus
        s.repaint
        editor.focused?.should be_true
        focused = cell_bg(s, 2, 2)
        other.focus
        s.repaint
        editor.focused?.should be_false
        cell_bg(s, 2, 2).should eq focused
        focused.should eq theme.shades("surface")[:dark]
      end
    end

    it "still lightens a #{theme.name} line edit while it has the focus" do
      s = headless_screen(40, 8)
      with_theme(theme) do
        field = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
        other = Widget::LineEdit.new parent: s, top: 2, left: 0, width: 20, height: 1
        field.focus
        s.repaint
        cell_bg(s, 10, 0).should eq theme.shades("surface")[:light]
        other.focus
        s.repaint
        cell_bg(s, 10, 0).should eq theme.shades("surface")[:dark]
      end
    end
  end
end
