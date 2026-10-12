require "./spec_helper"

include Crysterm

# What a menu says about its highlighted action (`menu/tips.cr`): the
# action's `status_tip` shows in a `MainWindow`'s status bar while the row
# is highlighted and is cleared when the highlight moves to an action without
# one or leaves; with `tool_tips_visible`, the `tool_tip` pops up beside the
# row after the wake-up delay and goes as the highlight moves or the menu
# closes; `F1` shows the `whats_this`.

private def press(w, key : Tput::Key)
  w.handle_key_press Crysterm::Event::KeyPress.new('\0', key)
end

private def hover(s, x, y)
  s.dispatch_mouse Tput::Mouse::Event.new(Tput::Mouse::Action::Move, Tput::Mouse::Button::None, x, y, source: :test)
end

# A main window with a File menu: Open (every tip), Save (none), Recent (a
# submenu whose rows have status tips).
private def tipped_window(s)
  main = Widget::MainWindow.new parent: s
  main.status_bar
  file = main.menu_bar.add_menu "File"
  open = file.add_action("Open") { }
  open.status_tip = "Open a file"
  open.tool_tip = "Opens a file of your choosing"
  open.whats_this = "Asks for a file name and opens that file in the window."
  file.add_action("Save") { }
  file.add_submenu "Recent", [Crysterm::Action.new("old-1", status_tip: "Open old-1 again")]
  s.repaint
  {main, file}
end

private def visible_tool_tip(s) : Widget::ToolTip?
  s.children.select(Widget::ToolTip).find(&.visible?)
end

describe "Widget::Menu tips" do
  it "shows the highlighted action's status tip in the status bar, clears it on a row without one and when the menu closes" do
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    hovered = [] of Crysterm::Action?
    file.on(Event::ActionHovered) { |e| hovered << e.action }
    main.menu_bar.open_menu 0
    s.repaint
    main.status_bar.message.should eq ""

    file.select_first_action # Open
    main.status_bar.message.should eq "Open a file"
    hovered.map(&.try &.text).should eq ["Open"]

    press file, Tput::Key::Down # Save: no tip, so the bar is cleared
    main.status_bar.message.should eq ""
    hovered.size.should eq 2

    press file, Tput::Key::Up
    main.status_bar.message.should eq "Open a file"
    press file, Tput::Key::Escape # closes the menu
    file.visible?.should be_false
    main.status_bar.message.should eq ""
    hovered.last.should be_nil
  end

  it "takes the tip from a hovered row too" do
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.menu_bar.open_menu 0
    s.repaint
    lp = file.lpos.not_nil!
    hover s, lp.xi + 2, lp.yi + file.itop # the first row, Open
    main.status_bar.message.should eq "Open a file"
    main.menu_bar.close
    main.status_bar.message.should eq ""
  end

  it "relays a submenu's tips through the bar, and the parent's row speaks again once the submenu is gone" do
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.menu_bar.open_menu 0
    s.repaint
    file.select_last_action # Recent
    main.status_bar.message.should eq ""
    press file, Tput::Key::Right # opens Recent with old-1 selected
    main.status_bar.message.should eq "Open old-1 again"
    press file.@submenu_open.not_nil!, Tput::Key::Left
    main.status_bar.message.should eq ""
    press file, Tput::Key::Up # Save
    press file, Tput::Key::Up # Open
    main.status_bar.message.should eq "Open a file"
    press file, Tput::Key::Down
    press file, Tput::Key::Down # Recent
    press file, Tput::Key::Right
    main.status_bar.message.should eq "Open old-1 again"
    press file.@submenu_open.not_nil!, Tput::Key::Escape
    main.status_bar.message.should eq ""
  end

  it "shows nothing with status tips off, and does not take down a message that is not the tip's" do
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.status_tips = false
    main.menu_bar.open_menu 0
    s.repaint
    file.select_first_action
    main.status_bar.message.should eq ""
    main.menu_bar.close

    main.status_tips = true
    main.menu_bar.open_menu 0
    s.repaint
    file.select_first_action
    main.status_bar.message.should eq "Open a file"
    main.status_bar.show_message "Saved", 10.seconds # the application's own word, newer than the tip
    main.menu_bar.close
    main.status_bar.message.should eq "Saved"
  end

  it "pops the tooltip up beside the row after the delay when asked, and hides it as the highlight moves or the menu closes" do
    Crysterm::Config.set "tool_tip.delay", 20.milliseconds
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.menu_bar.open_menu 0
    s.repaint
    file.tool_tips_visible?.should be_false # off by default, as Qt's QMenu::toolTipsVisible
    file.select_first_action
    sleep 80.milliseconds
    visible_tool_tip(s).should be_nil

    file.tool_tips_visible = true
    file.tool_tips_visible?.should be_true
    press file, Tput::Key::Down
    press file, Tput::Key::Up         # back on Open, tooltips now on
    visible_tool_tip(s).should be_nil # not before the wake-up
    wait_until { visible_tool_tip(s) }
    tip = visible_tool_tip(s).not_nil!
    tip.content.should eq " Opens a file of your choosing"
    s.repaint
    lp = file.lpos.not_nil!
    tip.aleft.should be >= lp.xl # beside the menu, to its right
    tip.atop.should eq lp.yi + file.itop

    press file, Tput::Key::Down # Save, which has none
    visible_tool_tip(s).should be_nil
    sleep 80.milliseconds
    visible_tool_tip(s).should be_nil

    press file, Tput::Key::Up
    wait_until { visible_tool_tip(s) }
    main.menu_bar.close
    visible_tool_tip(s).should be_nil
  ensure
    Crysterm::Config.reset "tool_tip.delay"
  end

  it "shows one tooltip at a time: a submenu's row takes the parent row's down" do
    Crysterm::Config.set "tool_tip.delay", 20.milliseconds
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    recent = file.actions.last
    recent.tool_tip = "The files opened before"
    recent.menu.not_nil!.first.tool_tip = "Open old-1 again"
    main.menu_bar.open_menu 0
    s.repaint
    file.tool_tips_visible = true
    file.select_last_action # Recent
    wait_until { visible_tool_tip(s) }
    visible_tool_tip(s).not_nil!.content.should eq " The files opened before"
    press file, Tput::Key::Right      # old-1 selected in the submenu
    visible_tool_tip(s).should be_nil # the parent's is down at once
    wait_until { visible_tool_tip(s) }
    s.children.select(Widget::ToolTip).count(&.visible?).should eq 1
    visible_tool_tip(s).not_nil!.content.should eq " Open old-1 again"
    press file.@submenu_open.not_nil!, Tput::Key::Left # the submenu closes with its tooltip
    visible_tool_tip(s).should be_nil
  ensure
    Crysterm::Config.reset "tool_tip.delay"
  end

  it "lets a submenu inherit the setting and follows the menu.tool_tips option when unset" do
    Crysterm::Config.set "tool_tip.delay", 20.milliseconds
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.menu_bar.open_menu 0
    s.repaint
    file.tool_tips_visible = true
    file.select_last_action
    press file, Tput::Key::Right
    file.@submenu_open.not_nil!.tool_tips_visible?.should be_true
    file.tool_tips_visible = nil
    file.@submenu_open.not_nil!.tool_tips_visible?.should be_false
    Crysterm::Config.set "menu.tool_tips", true
    file.tool_tips_visible?.should be_true
    file.@submenu_open.not_nil!.tool_tips_visible?.should be_true
  ensure
    Crysterm::Config.reset "tool_tip.delay"
    Crysterm::Config.reset "menu.tool_tips"
  end

  it "shows the What's This text on F1, until the highlight moves" do
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.menu_bar.open_menu 0
    s.repaint
    press file, Tput::Key::F1 # nothing highlighted yet: not consumed, nothing shown
    visible_tool_tip(s).should be_nil
    file.select_first_action
    e = Crysterm::Event::KeyPress.new('\0', Tput::Key::F1)
    file.handle_key_press e
    e.accepted?.should be_true
    tip = visible_tool_tip(s).not_nil!
    tip.content.should eq " Asks for a file name and opens that file in the window."
    press file, Tput::Key::Down
    visible_tool_tip(s).should be_nil
    e = Crysterm::Event::KeyPress.new('\0', Tput::Key::F1) # Save has no What's This
    file.handle_key_press e
    e.accepted?.should be_false
    visible_tool_tip(s).should be_nil
  end
end
