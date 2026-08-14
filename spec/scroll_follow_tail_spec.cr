require "./spec_helper"

include Crysterm

# `Widget#follow_tail`: view stays pinned to the bottom as content grows, but
# only while already at the bottom, so a manual scroll-up is preserved.

private def at_bottom?(w)
  w.scroll_percent >= 1.0
end

describe "follow_tail (sticky bottom)" do
  it "is on by default for Widget::Log and off for a generic scroll area" do
    s = headless_screen(default_quit_keys: true)
    Widget::Log.new(parent: s, top: 0, left: 0, width: 20, height: 5).follow_tail?.should be_true
    Widget::ScrollableText.new(parent: s, top: 0, left: 0, width: 20, height: 5).follow_tail?.should be_false
  end

  it "a Log follows the tail as lines are appended" do
    s = headless_screen(default_quit_keys: true)
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5
    20.times { |i| log.add "line #{i}" }
    s.update
    at_bottom?(log).should be_true
  end

  it "stops following once the user scrolls up, and resumes at the bottom" do
    s = headless_screen(default_quit_keys: true)
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5
    20.times { |i| log.add "line #{i}" }
    s.update
    at_bottom?(log).should be_true

    log.scroll -3 # scroll up to read back
    s.update
    at_bottom?(log).should be_false

    5.times { |i| log.add "more #{i}" } # appends must NOT yank us down
    s.update
    at_bottom?(log).should be_false

    log.scroll_percent = 1.0 # return to the bottom
    s.update
    3.times { |i| log.add "tail #{i}" }
    s.update
    at_bottom?(log).should be_true # following again
  end

  it "scroll_on_input pins to the bottom on new content even after scrolling up" do
    s = headless_screen(default_quit_keys: true)
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5, scroll_on_input: true
    20.times { |i| log.add "line #{i}" }
    s.update

    log.scroll -3
    s.update
    at_bottom?(log).should be_false # a plain scroll-up still works (no new content)

    log.add "fresh"
    s.update
    at_bottom?(log).should be_true # new content forced us back to the bottom
  end

  it "a generic scroll area follows the tail when enabled" do
    s = headless_screen(default_quit_keys: true)
    st = Widget::ScrollableText.new parent: s, top: 0, left: 0, width: 20, height: 5
    st.follow_tail = true
    st.content = (1..30).map { |i| "row #{i}" }.join('\n')
    s.update
    at_bottom?(st).should be_true
  end
end
