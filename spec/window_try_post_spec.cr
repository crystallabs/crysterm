require "./spec_helper"

include Crysterm

# `Window#post?`: `#post` that tells whether the job was queued, so a caller
# serving several windows can hand a job a destroyed window refused to
# another.
describe "Window#post?" do
  it "queues the job and returns true while the window is alive" do
    s = headless_screen(20, 3)
    done = Channel(Int32).new
    s.post? { done.send 42 }.should be_true
    select
    when v = done.receive
      v.should eq 42
    when timeout(2.seconds)
      fail "the posted job never ran"
    end
  end

  it "returns false after destroy and never runs the job" do
    s = headless_screen(20, 3)
    s.destroy
    ran = false
    s.post? { ran = true }.should be_false
    Fiber.yield
    sleep 50.milliseconds
    ran.should be_false
  end

  it "keeps #post silent on a destroyed window" do
    s = headless_screen(20, 3)
    s.destroy
    s.post { raise "must not run" }
  end
end
