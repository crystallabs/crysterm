require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Group L (ALLOCS.md): LineEdit#compute_display now snapshots its inputs and
# reuses a cached display string across the once-per-frame redisplay driven by
# Mixin::TextEditing#render (self.value = nil). These specs pin the displayed
# text (normal + censor), horizontal-scroll windowing, caret tracking, and that
# an unchanged steady-state frame returns the *same* String object.
describe "LineEdit display cache (ALLOCS Group L)" do
  it "displays a short value verbatim" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "hello"
    s._render
    box.@_value.should eq "hello"
    box.@view_start.should eq 0
  end

  it "masks the value in censor mode" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "secret", echo_mode: :password
    s._render
    box.@_value.should eq "******"
    box.value.should eq "secret" # underlying value unchanged
  end

  it "honors a custom password_character" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "abcd", echo_mode: :password
    box.password_character = '•'
    s._render
    box.@_value.should eq "••••"
  end

  it "shows the placeholder while empty and clears it once typed" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, placeholder_text: "type here"
    s._render
    box.@_value.should eq "type here"
    box.value = "x"
    s._render
    box.@_value.should eq "x"
  end

  it "scrolls a long value so the caret (at the end) stays visible" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 6, height: 1, content: "abcdefghij"
    s._render
    # cols = awidth(6) - ihorizontal(0) - 1 = 5; caret at end (10) -> window is the tail.
    box.@view_start.should be > 0
    box.@_value.size.should be <= 5
    box.@_value.should eq "fghij"
  end

  it "scrolls back to the head when the caret returns to the start" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 6, height: 1, content: "abcdefghij"
    box.read_input
    s._render
    box.@view_start.should be > 0

    # Move the caret to the very start (Home); the window must re-track it left.
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Home)
    s._render
    box.@view_start.should eq 0
    box.@_value.should eq "abcde"
  end

  it "reuses the same display String object across unchanged frames" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "steady"
    s._render
    first = box.@display_cache
    box.@display_key.should_not be_nil
    first.should eq "steady"

    # Several redisplay frames with nothing changed: the cached object is
    # returned untouched (no rebuild), so identity is preserved.
    5.times { s._render }
    box.@display_cache.object_id.should eq first.object_id
    box.@_value.object_id.should eq first.object_id
  end

  it "rebuilds the cache when the value changes" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "one"
    s._render
    before = box.@display_cache.object_id
    box.value = "two"
    s._render
    box.@display_cache.should eq "two"
    box.@display_cache.object_id.should_not eq before
  end

  it "rebuilds the cache when the width changes" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 6, height: 1, content: "abcdefghij"
    s._render
    box.@_value.should eq "fghij"
    box.width = 12
    s._render
    # A wider box shows more of the value.
    box.@_value.size.should be > 5
  end
end
