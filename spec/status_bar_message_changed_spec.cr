require "./spec_helper"

include Crysterm

# `Event::MessageChanged` (Qt's `QStatusBar::messageChanged`): every change of
# the temporary message is reported, and an unchanged one is not.
describe "StatusBar MessageChanged" do
  it "reports shown, replaced and cleared messages, not repeats" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    seen = [] of String
    bar.on(Event::MessageChanged) { |e| seen << e.message }
    bar.clear_message # nothing showing: a no-op
    bar.show_message "Saved"
    bar.show_message "Saved" # the same text again: no change
    bar.show_message "Saving…"
    bar.message = "Saved"
    bar.clear_message
    bar.clear_message
    seen.should eq ["Saved", "Saving…", "Saved", ""]
    bar.message.should eq ""
  end

  it "reports the clear a timeout brings, and only for the message that armed it" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    name = bar.add_widget Widget::Label.new(content: "notes.md")
    seen = [] of String
    bar.on(Event::MessageChanged) { |e| seen << e.message }
    bar.show_message "Gone soon", 20.milliseconds
    name.visible?.should be_false
    # Replacing the message cancels the pending timeout; the new one stays.
    bar.show_message "Stays"
    wait_until { seen.size >= 2 }
    sleep 40.milliseconds
    s.repaint
    seen.should eq ["Gone soon", "Stays"]
    bar.message.should eq "Stays"
    # A timed message left alone clears itself, and says so.
    bar.show_message "Gone soon", 20.milliseconds
    wait_until(1.second) do
      s.repaint
      bar.message.empty?
    end
    seen.last.should eq ""
    name.visible?.should be_true
  end

  it "disarms a pending timeout when the bar is destroyed" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    seen = [] of String
    bar.on(Event::MessageChanged) { |e| seen << e.message }
    bar.show_message "Gone soon", 20.milliseconds
    bar.destroy
    sleep 40.milliseconds
    s.repaint
    seen.should eq ["Gone soon"]
  end
end
