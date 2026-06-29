require "./spec_helper"

include Crysterm

# Qt-style sticky-bottom "follow tail" (`Widget#follow_tail`): the view stays
# pinned to the bottom as content grows, but only while already at the bottom, so
# a manual scroll-up is preserved. Driven headlessly through real widgets.

private def ft_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def at_bottom?(w)
  w.get_scroll_perc(false) >= 100
end

describe "follow_tail (sticky bottom)" do
  it "is on by default for Widget::Log and off for a generic scroll area" do
    s = ft_screen
    Widget::Log.new(parent: s, top: 0, left: 0, width: 20, height: 5).follow_tail?.should be_true
    Widget::ScrollableText.new(parent: s, top: 0, left: 0, width: 20, height: 5).follow_tail?.should be_false
  end

  it "a Log follows the tail as lines are appended" do
    s = ft_screen
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5
    20.times { |i| log.add "line #{i}" }
    s.render
    at_bottom?(log).should be_true
  end

  it "stops following once the user scrolls up, and resumes at the bottom" do
    s = ft_screen
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5
    20.times { |i| log.add "line #{i}" }
    s.render
    at_bottom?(log).should be_true

    log.scroll -3 # scroll up to read back
    s.render
    at_bottom?(log).should be_false

    5.times { |i| log.add "more #{i}" } # appends must NOT yank us down
    s.render
    at_bottom?(log).should be_false

    log.set_scroll_perc 100 # return to the bottom
    s.render
    3.times { |i| log.add "tail #{i}" }
    s.render
    at_bottom?(log).should be_true # following again
  end

  it "scroll_on_input pins to the bottom on new content even after scrolling up" do
    s = ft_screen
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5, scroll_on_input: true
    20.times { |i| log.add "line #{i}" }
    s.render

    log.scroll -3
    s.render
    at_bottom?(log).should be_false # a plain scroll-up still works (no new content)

    log.add "fresh"
    s.render
    at_bottom?(log).should be_true # new content forced us back to the bottom
  end

  it "a generic scroll area follows the tail when enabled" do
    s = ft_screen
    st = Widget::ScrollableText.new parent: s, top: 0, left: 0, width: 20, height: 5
    st.follow_tail = true
    st.content = (1..30).map { |i| "row #{i}" }.join('\n')
    s.render
    at_bottom?(st).should be_true
  end
end
