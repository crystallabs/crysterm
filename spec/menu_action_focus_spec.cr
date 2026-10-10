require "./spec_helper"

include Crysterm

# A menu action fires only after the menus closed and the bar handed focus
# back (Qt's `QMenu` hides before triggering), so an action that takes focus
# itself — opening a prompt line, a dialog — keeps it.
describe "menu activation order" do
  it "lets an action that focuses a widget keep that focus" do
    s = headless_screen(40, 8)
    win = Widget::MainWindow.new parent: s
    editor = Widget::PlainTextEdit.new
    win.central_widget = editor
    field = Widget::LineEdit.new parent: s, bottom: 0, left: 0, width: 20, height: 1, input_on_focus: false
    order = [] of String
    menu = win.menu_bar.add_menu "&File"
    menu.add_action("Ask") do
      order << "fired:#{s.focused.class.name.split("::").last}"
      field.focus
    end
    editor.focus
    s.repaint
    win.menu_bar.open_menu 0
    s.repaint
    menu.select_first_action
    menu.activate_selected
    s.repaint
    order.should eq ["fired:PlainTextEdit"] # the central area had focus back already
    field.focused?.should be_true
    menu.visible?.should be_false
  end
end
