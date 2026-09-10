require "./spec_helper"

include Crysterm

# InputDialog's no-argument `#open` (and therefore `#exec`, which calls it):
# wires the OK/Cancel buttons and starts the embedded field's read session the
# same way the block-based `#open`/`.read` do, so accept/reject (Enter/Escape,
# OK/Cancel) actually close the dialog.

describe "InputDialog bare #open / #exec" do
  it "accept closes the dialog opened via the no-argument #open" do
    s = headless_screen(60, 24)
    d = Widget::InputDialog.new parent: s, content: "Name?"
    log = [] of String
    d.on(Crysterm::Event::Accepted) { log << "accepted" }
    d.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

    d.open
    d.modal?.should be_true
    s.popup_grab_active?.should be_true

    d.accept

    log.should eq ["accepted", "finished=#{Widget::Dialog::Code::Accepted.to_i}"]
    d.accepted?.should be_true
    d.modal?.should be_false
    s.popup_grab_active?.should be_false
    d.visible?.should be_false
  end

  it "reject closes the dialog opened via the no-argument #open" do
    s = headless_screen(60, 24)
    d = Widget::InputDialog.new parent: s, content: "Name?"
    log = [] of String
    d.on(Crysterm::Event::Rejected) { log << "rejected" }
    d.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

    d.open
    d.reject

    log.should eq ["rejected", "finished=#{Widget::Dialog::Code::Rejected.to_i}"]
    d.accepted?.should be_false
    d.modal?.should be_false
    s.popup_grab_active?.should be_false
  end

  it "#exec blocks the calling fiber until the dialog closes, returning the result" do
    s = headless_screen(60, 24)
    d = Widget::InputDialog.new parent: s, content: "Name?"
    done = Channel(Int32).new

    spawn { done.send d.exec }
    wait_until { d.modal? }

    d.accept

    done.receive.should eq Widget::Dialog::Code::Accepted.to_i
    d.modal?.should be_false
  end
end

# `DateTimeEdit#set_date_time_range` (reached from `minimum_date_time=`/
# `maximum_date_time=`) re-clamps the edit's actual current value — `DateEdit`
# and `TimeEdit` track theirs in their own ivar, not the base class's — so a
# bound that doesn't affect that value leaves it untouched and silent, while a
# bound that excludes it clamps the value in and fires one change event.
# `DateEdit#date=`/`TimeEdit#time=` clamp the same way on a direct set.

describe "DateEdit bound re-clamping" do
  it "keeps the current date when an unrelated minimum is set" do
    s = headless_screen(60, 24)
    de = Widget::DateEdit.new parent: s, date: Time.utc(2020, 1, 15)
    changed = [] of Time
    de.on(Crysterm::Event::DateChanged) { |e| changed << e.date }

    de.minimum_date_time = Time.utc(1990, 1, 1)

    de.date.should eq Time.utc(2020, 1, 15)
    changed.should be_empty
  end

  it "clamps the date in and fires DateChanged when the new minimum excludes it" do
    s = headless_screen(60, 24)
    de = Widget::DateEdit.new parent: s, date: Time.utc(2020, 1, 15)
    changed = [] of Time
    de.on(Crysterm::Event::DateChanged) { |e| changed << e.date }

    de.minimum_date_time = Time.utc(2025, 1, 1)

    de.date.should eq Time.utc(2025, 1, 1)
    changed.should eq [Time.utc(2025, 1, 1)]
  end

  it "clamps the date in and fires DateChanged when the new maximum excludes it" do
    s = headless_screen(60, 24)
    de = Widget::DateEdit.new parent: s, date: Time.utc(2020, 1, 15)
    changed = [] of Time
    de.on(Crysterm::Event::DateChanged) { |e| changed << e.date }

    de.maximum_date_time = Time.utc(2010, 1, 1)

    de.date.should eq Time.utc(2010, 1, 1)
    changed.should eq [Time.utc(2010, 1, 1)]
  end

  it "#date= clamps directly into the configured bounds" do
    s = headless_screen(60, 24)
    de = Widget::DateEdit.new parent: s, date: Time.utc(2020, 1, 15)
    de.minimum_date_time = Time.utc(2022, 1, 1)
    de.maximum_date_time = Time.utc(2023, 1, 1)

    de.date = Time.utc(2030, 6, 1)
    de.date.should eq Time.utc(2023, 1, 1)

    de.date = Time.utc(1999, 6, 1)
    de.date.should eq Time.utc(2022, 1, 1)
  end
end

describe "TimeEdit bound re-clamping" do
  it "#time= clamps directly into the configured bounds" do
    s = headless_screen(60, 24)
    te = Widget::TimeEdit.new parent: s, time: Time.utc(2000, 1, 1, 10, 0, 0)
    te.minimum_date_time = Time.utc(2000, 1, 1, 9, 0, 0)
    te.maximum_date_time = Time.utc(2000, 1, 1, 17, 0, 0)

    te.time = Time.utc(2000, 1, 1, 20, 0, 0)
    te.time.should eq Time.utc(2000, 1, 1, 17, 0, 0)

    te.time = Time.utc(2000, 1, 1, 3, 0, 0)
    te.time.should eq Time.utc(2000, 1, 1, 9, 0, 0)
  end
end
