require "./spec_helper"

# Regression specs for the core (application, screen, frame clock, layout
# engines, file watcher, glyph registry) fixes.

describe "FrameClock tween restarted from its own final tick" do
  it "runs the restarted tween instead of ending it with the old run's completion" do
    ticks = 0
    stopped = 0
    clock = Crysterm::FrameClock.tween(1.millisecond, duration: Time::Span.zero) do |c|
      ticks += 1
      if ticks == 1
        c.stop
        c.start
      end
    end
    clock.stop_handler { stopped += 1 }
    clock.start

    wait_until { stopped > 0 }
    ticks.should eq 2
    stopped.should eq 1
    clock.completed?.should be_true
    clock.running?.should be_false
  end
end

describe "Flow layouts with a pathologically large child" do
  it "wraps past a child of Int32::MAX height with spacing set" do
    s = headless_screen(80, 24)
    lay = Crysterm::Layout::Wrap.new
    lay.spacing = 1
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 20,
      layout: lay
    tall = Crysterm::Widget::Box.new parent: box, width: 30, height: Int32::MAX
    # 30 + 1 + 30 > 40: the second child wraps, advancing the row cursor by
    # the first row's height plus the spacing.
    Crysterm::Widget::Box.new parent: box, width: 30, height: 2

    s.repaint
    tall.lpos.nil?.should be_false
  ensure
    s.try &.destroy
  end

  it "snaps to a UniformGrid column pitch of Int32::MAX" do
    s = headless_screen(80, 24)
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 20,
      layout: Crysterm::Layout::UniformGrid.new
    wide = Crysterm::Widget::Box.new parent: box, width: Int32::MAX, height: 2
    Crysterm::Widget::Box.new parent: box, width: 5, height: 2

    s.repaint
    wide.lpos.nil?.should be_false
  ensure
    s.try &.destroy
  end
end

describe "Flow layout after a z-indexed child on its first frame" do
  it "chains the successor off the z-indexed child, not off the child before it" do
    s = headless_screen(80, 24)
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      layout: Crysterm::Layout::Wrap.new
    Crysterm::Widget::Box.new parent: box, width: 10, height: 2
    layered = Crysterm::Widget::Box.new parent: box, width: 10, height: 2
    layered.style.z_index = 1
    after = Crysterm::Widget::Box.new parent: box, width: 10, height: 2

    # One frame only: the z-indexed child has no rendered rect yet.
    s.repaint

    bl = box.lpos.not_nil!
    al = after.lpos.not_nil!
    al.xi.should eq bl.xi + 20
    al.yi.should eq bl.yi
  ensure
    s.try &.destroy
  end
end

describe "Layout::Form with a negative label width" do
  it "starts the field column at the spacing, not left of the label column" do
    s = headless_screen(80, 24)
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 10,
      layout: Crysterm::Layout::Form.new(label_width: -5)
    Crysterm::Widget::Box.new parent: box, height: 1, content: "Name"
    field = Crysterm::Widget::Box.new parent: box, height: 1

    s.repaint

    bl = box.lpos.not_nil!
    field.lpos.not_nil!.xi.should eq bl.xi + 1
  ensure
    s.try &.destroy
  end
end

describe "FileWatcher with a path that cannot be looked at" do
  it "watches it as absent instead of raising" do
    watcher = Crysterm::FileWatcher.new 20.milliseconds
    # Longer than any file system's name limit: `stat` fails with
    # ENAMETOOLONG rather than ENOENT.
    path = "x" * 5000
    watcher.add_path path
    watcher.paths.should eq [path]
  ensure
    watcher.try &.stop
  end
end

describe "Screen#reconnected" do
  it "carries the pointer-shape policy onto the new device" do
    screen = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 10, height: 5)
    screen.mouse_cursor_shaping = false

    fresh = screen.reconnected IO::Memory.new, IO::Memory.new
    fresh.mouse_cursor_shaping.off?.should be_true
    fresh.mouse_cursor_shaping?.should be_false
  end
end

describe "Application.destroy_windows" do
  it "tears down the windows after one whose teardown raises, and returns that error" do
    first = headless_screen(20, 5)
    second = headless_screen(20, 5)
    w = Crysterm::Widget::Box.new parent: first, top: 0, left: 0, width: 5, height: 2
    w.on(Crysterm::Event::Destroy) { raise "boom" }

    error = Crysterm::Application.destroy_windows [first, second]

    error.nil?.should be_false
    error.try(&.message).should eq "boom"
    first.destroyed?.should be_true
    second.destroyed?.should be_true
  end

  it "returns nil when every teardown is clean" do
    first = headless_screen(20, 5)
    Crysterm::Application.destroy_windows([first]).nil?.should be_true
    first.destroyed?.should be_true
  end
end

describe "Glyphs::Entry#str" do
  it "falls down to the ascii glyph as one shared String" do
    entry = Crysterm::Glyphs::Entry.new('x')
    entry.str(Crysterm::Glyphs::Tier::Extended).should eq "x"
    entry.str(Crysterm::Glyphs::Tier::Unicode).should eq "x"
    entry.str(Crysterm::Glyphs::Tier::Ascii).should eq "x"
    entry.str(Crysterm::Glyphs::Tier::Unicode).same?(entry.str(Crysterm::Glyphs::Tier::Ascii)).should be_true
  end

  it "prefers the tier's own grapheme" do
    entry = Crysterm::Glyphs::Entry.new('x', "y", "zz")
    entry.str(Crysterm::Glyphs::Tier::Extended).should eq "zz"
    entry.str(Crysterm::Glyphs::Tier::Unicode).should eq "y"
    entry.str(Crysterm::Glyphs::Tier::Ascii).should eq "x"
  end
end
