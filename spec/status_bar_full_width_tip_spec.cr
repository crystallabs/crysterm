require "./spec_helper"

include Crysterm

private def row(s, width)
  (s.dump(0, width, 2, 3) || "").lines[2][1..-2]
end

private def field(text, **opts)
  Widget::Label.new **opts, content: text
end

private def bar_with_fields(s)
  bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
  name = bar.add_widget field("notes.md")
  pos = bar.add_permanent_widget field("Ln 1", width: 10)
  bar.add_permanent "UTF-8"
  s.repaint
  {bar, name, pos}
end

# Lets the render fiber run the jobs posted to it (`Window#post`).
private def settle(s)
  done = Channel(Nil).new
  s.post { done.send nil }
  select
  when done.receive
  when timeout(2.seconds)
    fail "posted jobs never ran"
  end
end

# `StatusBar#show_message(full_width: true)`: a message that may take the
# permanent fields' cells as well, as much as it needs — beside them when it
# fits, over them when it does not — and `MainWindow#status_tips_full_width`,
# which shows the status tips that way.
describe "StatusBar full-width messages" do
  it "leaves the permanent fields be when the message fits beside them" do
    s = headless_screen(40, 3)
    bar, name, pos = bar_with_fields s
    bar.show_message "Short", full_width: true
    bar.full_width_message?.should be_true
    name.visible?.should be_false
    pos.visible?.should be_true
    s.repaint
    line = row s, 40
    line.should start_with "Short"
    line.should contain "UTF-8"
    line[30, 4].should eq "Ln 1"
  end

  it "covers the permanent fields and sections when it does not fit, and brings them back when it clears" do
    s = headless_screen(40, 3)
    bar, name, pos = bar_with_fields s
    long = "Open a file from disk into a new tab now"[0, 38]
    bar.show_message long, full_width: true
    pos.visible?.should be_false
    s.repaint
    row(s, 40).should start_with long
    row(s, 40).should_not contain "UTF-8"

    bar.clear_message
    bar.full_width_message?.should be_false
    pos.visible?.should be_true
    name.visible?.should be_true
    s.repaint
    line = row s, 40
    line.should start_with "notes.md" # the normal field takes the sections' room again
    line[30, 4].should eq "Ln 1"
  end

  it "keeps Qt's behavior for an ordinary message, and an ordinary message replacing a covering one uncovers" do
    s = headless_screen(40, 3)
    bar, _name, pos = bar_with_fields s
    long = "x" * 36
    bar.show_message long
    pos.visible?.should be_true
    s.repaint
    row(s, 40)[30, 4].should eq "Ln 1"

    bar.show_message long, full_width: true # same text, now full width
    pos.visible?.should be_false
    bar.show_message long # and back
    pos.visible?.should be_true
    bar.show_message long, full_width: true
    pos.visible?.should be_false
    bar.show_message "Saved", 1.hour
    pos.visible?.should be_true
  end

  it "does not show again a field the application hid, and lets a removed field go shown" do
    s = headless_screen(40, 3)
    bar, _name, pos = bar_with_fields s
    other = bar.add_permanent_widget field("INS", width: 5)
    s.repaint
    other.hide
    bar.show_message "y" * 38, full_width: true
    pos.visible?.should be_false
    bar.remove_permanent_widget pos
    pos.visible?.should be_true
    bar.clear_message
    other.visible?.should be_false
  end

  it "corrects the decision on the next frame when the bar was not painted yet" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    pos = bar.add_permanent_widget field("Ln 1", width: 10)
    bar.show_message "z" * 36, full_width: true
    pos.visible?.should be_true # nothing measured yet
    s.repaint
    settle s
    pos.visible?.should be_false
    s.repaint
    row(s, 40).should start_with "z" * 36
  end

  it "uncovers the fields when the bar grows wide enough for the message, and covers them again when it shrinks" do
    s = headless_screen(60, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: 40, height: 1
    pos = bar.add_permanent_widget field("Ln 1", width: 10)
    s.repaint
    bar.show_message "q" * 32, full_width: true
    pos.visible?.should be_false

    bar.width = 60
    s.repaint
    settle s
    pos.visible?.should be_true
    s.repaint
    line = row s, 60
    line.should start_with "q" * 32
    line[50, 4].should eq "Ln 1"

    bar.width = 40
    s.repaint
    settle s
    pos.visible?.should be_false
  end

  it "lets the timeout of a full-width message clear only its own message" do
    s = headless_screen(40, 3)
    bar, _name, pos = bar_with_fields s
    bar.show_message "w" * 38, 20.milliseconds, full_width: true
    pos.visible?.should be_false
    sleep 80.milliseconds
    settle s
    bar.message.should eq ""
    pos.visible?.should be_true

    bar.show_message "w" * 38, 20.milliseconds, full_width: true
    bar.show_message "v" * 38, full_width: true # supersedes; the timer is stale
    sleep 80.milliseconds
    settle s
    bar.message.should eq "v" * 38
    pos.visible?.should be_false
  end
end

describe "MainWindow#status_tips_full_width" do
  it "shows a tip over the permanent fields, keeps an application notice that raced it, and restores the bar" do
    s = headless_screen(40, 6)
    main = Widget::MainWindow.new parent: s
    bar = main.status_bar
    pos = bar.add_permanent_widget field("Ln 1", width: 10)
    s.repaint
    main.status_tips_full_width?.should be_false
    tip = "Open a file from disk, in a new tab"

    main.emit Event::StatusTip, tip
    pos.visible?.should be_true # off: Qt's behavior
    main.status_tips_full_width = true
    pos.visible?.should be_false # the tip showing is put up again
    main.emit Event::StatusTip, ""
    bar.message.should eq ""
    pos.visible?.should be_true

    main.emit Event::StatusTip, tip
    pos.visible?.should be_false
    bar.show_message "Saved", 1.hour # the application's notice races the tip
    pos.visible?.should be_true
    main.emit Event::StatusTip, "" # not the tip's message: it stays
    bar.message.should eq "Saved"
    pos.visible?.should be_true

    main.emit Event::StatusTip, "Fits"
    pos.visible?.should be_true
    main.status_tips_full_width = false
    main.emit Event::StatusTip, tip
    pos.visible?.should be_true
  end
end
