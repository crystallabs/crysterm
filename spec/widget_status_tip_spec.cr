require "./spec_helper"

include Crysterm

# `Widget#status_tip` (Qt's `QWidget#statusTip`): the pointer entering a
# widget with a tip sends the tip up to the `MainWindow`, which shows it in
# its status bar; the pointer leaving takes it down again. The menus' tips,
# which share the status bar and the `status_tips` switch, are in
# `menu_tips_spec.cr` and `main_window_status_tips_spec.cr`.

private def move_to(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y, source: :test)
end

# A main window with a status bar, and a central box holding a label at
# (2, 1)–(11, 1) whose tip is "Saves the file".
private def tipped_window(s)
  main = Widget::MainWindow.new parent: s
  main.status_bar
  box = Widget::Box.new
  main.central_widget = box
  label = Widget::Label.new parent: box, top: 1, left: 2, width: 10, height: 1, content: "Save"
  label.status_tip = "Saves the file"
  s.repaint
  {main, box, label}
end

describe "Widget#status_tip" do
  it "shows in the main window's status bar while the pointer is over the widget" do
    s = headless_screen(80, 24)
    main, _box, label = tipped_window(s)
    label.status_tip.should eq "Saves the file"
    main.status_bar.message.should eq ""

    move_to s, 4, 1
    s.hovered.should eq label
    main.status_bar.message.should eq "Saves the file"

    move_to s, 40, 10
    main.status_bar.message.should eq ""
  end

  it "takes the tip down when the hovered widget is hidden" do
    s = headless_screen(80, 24)
    main, _box, label = tipped_window(s)
    move_to s, 4, 1
    main.status_bar.message.should eq "Saves the file"
    label.hide
    main.status_bar.message.should eq ""
  end

  it "leaves an application message put up while hovering in place" do
    s = headless_screen(80, 24)
    main, _box, _label = tipped_window(s)
    move_to s, 4, 1
    main.status_bar.show_message "Saved"
    move_to s, 40, 10
    main.status_bar.message.should eq "Saved"
  end

  it "shows nothing while the main window's status tips are off" do
    s = headless_screen(80, 24)
    main, _box, _label = tipped_window(s)
    main.status_tips = false
    move_to s, 4, 1
    main.status_bar.message.should eq ""
    move_to s, 40, 10
    main.status_bar.message.should eq ""
  end

  it "shows nothing for a nil or empty tip" do
    s = headless_screen(80, 24)
    main, _box, label = tipped_window(s)
    label.status_tip = ""
    move_to s, 4, 1
    main.status_bar.message.should eq ""
    move_to s, 40, 10
    label.status_tip = nil
    move_to s, 4, 1
    main.status_bar.message.should eq ""
  end

  it "takes down the tip it showed even when the text was dropped meanwhile" do
    s = headless_screen(80, 24)
    main, _box, label = tipped_window(s)
    move_to s, 4, 1
    label.status_tip = nil
    move_to s, 40, 10
    main.status_bar.message.should eq ""
  end

  it "travels up to the main window, past the parents, which hear it too" do
    s = headless_screen(80, 24)
    _main, box, _label = tipped_window(s)
    heard = [] of String
    box.on(Event::StatusTip) { |e| heard << e.text }
    move_to s, 4, 1
    move_to s, 40, 10
    heard.should eq ["Saves the file", ""]
  end

  it "does not lend a parent's tip to a child without one" do
    s = headless_screen(80, 24)
    main, box, label = tipped_window(s)
    label.status_tip = nil
    box.status_tip = "The document"
    # A child the pointer can hover is the hovered widget on its own: its
    # parent is left, and the child has no tip of its own to show.
    label.on(Event::Click) { }
    s.repaint
    move_to s, 40, 10
    main.status_bar.message.should eq "The document"
    move_to s, 4, 1
    s.hovered.should eq label
    main.status_bar.message.should eq ""
  end

  it "comes from the constructor argument too" do
    s = headless_screen(80, 24)
    label = Widget::Label.new parent: s, status_tip: "Saves the file"
    label.status_tip.should eq "Saves the file"
  end
end
