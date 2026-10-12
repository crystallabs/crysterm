require "./spec_helper"

include Crysterm

# `MainWindow#status_tips=`: the switch for the status tips the menus send
# (`menu_tips_spec.cr` has the tips themselves). Thrown while a tip is up
# — from the very menu entry that offers the choice, as a rule — it takes
# the tip down, so the bar is not left saying what a highlight no longer
# says.

private def press(w, key : Tput::Key)
  w.handle_key_press Crysterm::Event::KeyPress.new('\0', key)
end

private def tipped_window(s)
  main = Widget::MainWindow.new parent: s
  main.status_bar
  file = main.menu_bar.add_menu "File"
  open = file.add_action("Open") { }
  open.status_tip = "Open a file"
  file.add_action("Save") { }
  s.repaint
  {main, file}
end

describe "MainWindow#status_tips=" do
  it "takes down the tip showing when the tips are turned off, and leaves the bar alone otherwise" do
    s = headless_screen(80, 24)
    main, file = tipped_window(s)
    main.menu_bar.open_menu 0
    s.repaint
    file.select_first_action
    main.status_bar.message.should eq "Open a file"

    main.status_tips = false
    main.status_bar.message.should eq ""
    # The highlight leaving now has nothing to clear, and nothing to show.
    press file, Tput::Key::Down
    press file, Tput::Key::Up
    main.status_bar.message.should eq ""
    main.menu_bar.close

    # Turned off with the application's own message up, the message stays:
    # it is not the tip's.
    main.status_tips = true
    main.status_bar.show_message "Saved"
    main.status_tips = false
    main.status_bar.message.should eq "Saved"
    main.status_tips = false # no change: nothing happens
    main.status_bar.message.should eq "Saved"
  end

  it "stops hearing a menu bar taken out of the slot" do
    s = headless_screen(80, 24)
    main, _file = tipped_window(s)
    old = main.menu_bar
    main.menu_bar = Widget::MenuBar.new
    old.emit Event::StatusTip, "stale"
    main.status_bar.message.should eq ""
    main.menu_bar.emit Event::StatusTip, "fresh"
    main.status_bar.message.should eq "fresh"
    main.menu_bar = nil
    main.status_bar.message.should eq "fresh" # the slot emptied, nothing is heard
  end
end
