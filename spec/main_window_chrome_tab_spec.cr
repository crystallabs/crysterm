require "./spec_helper"

include Crysterm

# Window chrome (menu bar, tool bars, status bar) stays out of the window's
# default Tab/Shift+Tab cycle: MenuBar/ToolBar default to `FocusPolicy::Click`
# (StatusBar is a plain non-keyable Box), so keyboard cycling moves between the
# actual content widgets only. A click still focuses the bars, and an explicit
# `focus_policy:` argument puts one back into the chain.

describe "MainWindow chrome vs Tab navigation" do
  it "skips the menu bar, tool bar and status bar when cycling focus" do
    s = headless_screen(default_quit_keys: true)
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: "100%", height: "100%"
    win.menu_bar.add_menu "File"
    win.add_tool_bar Widget::ToolBar.new
    win.status_bar.show_message "Ready"
    a = Widget::Box.new parent: win, keys: true
    b = Widget::Box.new parent: win, keys: true

    a.focus
    s.focused.should eq a
    s.focus_next
    s.focused.should eq b
    s.focus_next # wraps around, stepping over all three bars
    s.focused.should eq a
    s.focus_previous
    s.focused.should eq b
  end

  it "keeps the bars click-focusable and directly focusable" do
    s = headless_screen(default_quit_keys: true)
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: "100%", height: "100%"
    mb = win.menu_bar
    tb = Widget::ToolBar.new
    win.add_tool_bar tb

    mb.accepts_tab_focus?.should be_false
    tb.accepts_tab_focus?.should be_false
    mb.focus_policy.accepts_click?.should be_true
    tb.focus_policy.accepts_click?.should be_true

    mb.focus # programmatic (or click) focus still lands on the bar
    s.focused.should eq mb
  end

  it "honors an explicit focus_policy: argument over the skip default" do
    s = headless_screen(default_quit_keys: true)
    bar = Widget::MenuBar.new parent: s, focus_policy: Widget::FocusPolicy::Strong
    tbar = Widget::ToolBar.new parent: s, focus_policy: Widget::FocusPolicy::Strong
    bar.accepts_tab_focus?.should be_true
    tbar.accepts_tab_focus?.should be_true
  end
end
