require "./spec_helper"

include Crysterm

private def ptv_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def ptv_long_text
  String.build do |s|
    50.times { |i| s << "Line " << i << '\n' }
  end
end

private def press(view, key : Tput::Key)
  view.on_keypress Crysterm::Event::KeyPress.new('\0', key)
end

describe "Pine::TextView" do
  it "scrolls down when Down is pressed" do
    s = ptv_screen
    view = Crysterm::Widget::Pine::TextView.new \
      content: ptv_long_text, parent: s, top: 0, left: 0, width: "100%", height: 10
    view.scroll_position.should eq 0

    press view, Tput::Key::Down
    view.scroll_position.should be > 0
  end

  it "returns to the top when Home is pressed" do
    s = ptv_screen
    view = Crysterm::Widget::Pine::TextView.new \
      content: ptv_long_text, parent: s, top: 0, left: 0, width: "100%", height: 10

    press view, Tput::Key::PageDown
    view.scroll_position.should be > 0

    press view, Tput::Key::Home
    view.scroll_position.should eq 0
  end

  it "replaces content and resets scroll with #text=" do
    s = ptv_screen
    view = Crysterm::Widget::Pine::TextView.new \
      content: ptv_long_text, parent: s, top: 0, left: 0, width: "100%", height: 10

    press view, Tput::Key::PageDown
    view.scroll_position.should be > 0

    view.text = "Fresh content"
    view.scroll_position.should eq 0
    view.content.should contain "Fresh content"
  end
end
