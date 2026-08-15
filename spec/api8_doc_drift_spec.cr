require "./spec_helper"

include Crysterm

# Coverage for the §8 documentation-drift round's code changes: the
# `key_policy` bundle, the hoisted `Widget#paint_handler` hook, and the
# block form of the pine/mutt packs' `callback` slots.

private def headless_window(width = 20, height = 6)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

describe "Window#key_policy" do
  it ":app_owns turns off default quit keys and tab navigation" do
    win = headless_window
    win.default_quit_keys?.should be_true
    win.tab_navigation?.should be_true
    win.key_policy = :app_owns
    win.default_quit_keys?.should be_false
    win.tab_navigation?.should be_false
    win.destroy
  end

  it ":framework restores both toggles" do
    win = headless_window
    win.key_policy = :app_owns
    win.key_policy = :framework
    win.default_quit_keys?.should be_true
    win.tab_navigation?.should be_true
    win.destroy
  end

  it "is accepted as a constructor kwarg and rejects unknown values" do
    win = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 20, height: 6, key_policy: :app_owns)
    win.default_quit_keys?.should be_false
    win.tab_navigation?.should be_false
    expect_raises(ArgumentError, /key_policy/) { win.key_policy = :whatever }
    win.destroy
  end
end

describe "Widget#paint_handler" do
  it "replaces the standard pass with the block, handed the content rect" do
    win = headless_window 20, 6
    box = Widget::Box.new parent: win, top: 0, left: 0, width: 10, height: 4
    rect = nil
    box.paint_handler { |xi, xl, yi, yl| rect = {xi, xl, yi, yl} }
    win.repaint
    r = rect
    r.should_not be_nil
    if r
      (r[1] - r[0]).should eq 10 # no border/padding: content == full width
      (r[3] - r[2]).should eq 4
    end
    win.destroy
  end

  it "clear_paint_handler restores the standard pass" do
    win = headless_window 20, 6
    box = Widget::Box.new parent: win, top: 0, left: 0, width: 10, height: 4
    calls = 0
    box.paint_handler { |_xi, _xl, _yi, _yl| calls += 1 }
    win.repaint
    calls.should eq 1
    box.clear_paint_handler
    win.repaint
    calls.should eq 1
    win.destroy
  end
end

describe "pine/mutt pack callback block forms" do
  it "Mutt::Mailbox#callback takes a block whose value is discarded" do
    mb = Widget::Mutt::Mailbox.new "INBOX"
    called = false
    mb.callback do
      called = true
      1 + 1 # non-nil last expression: no trailing `nil` needed
    end
    mb.callback.try &.call
    called.should be_true
  end

  it "Pine::Setup option callback receives the toggled value" do
    opt = Widget::Pine::SetupOption.new "enable-thing"
    got = nil
    opt.callback { |on| got = on }
    opt.callback.try &.call(true)
    got.should be_true
  end
end
