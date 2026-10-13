require "./spec_helper"

# A hidden window (`Window#hide`, Qt's `QWindow::hide`) has handed its
# terminal back: the render loop paints nothing while it stays hidden, so an
# update requested then (a timer, a `post` job, a resize) does not draw the
# window's frame over the shell's screen, nor does a resize clear that screen,
# and `#show` (or `Application#show`) repaints it whole.

describe "Window#hide" do
  it "paints nothing while hidden and everything again on show" do
    output = IO::Memory.new
    w = Crysterm::Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    box = Crysterm::Widget::Box.new parent: w, left: 0, top: 0, width: 20, height: 3, content: "before"
    w.repaint
    w.hide
    w.tput.flush
    mark = output.to_s.size

    box.set_content "while hidden"
    w.update
    sleep 50.milliseconds
    w.tput.flush
    output.to_s[mark..].should_not contain "hidden"

    w.show
    sleep 50.milliseconds
    w.tput.flush
    output.to_s[mark..].should contain "hile hidden"
  ensure
    w.try &.destroy
  end

  it "leaves the terminal uncleared when it is resized while hidden" do
    output = IO::Memory.new
    w = Crysterm::Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w.repaint
    w.hide
    w.tput.flush
    mark = output.to_s.size

    w.screen.resize 50, 12
    w.handle_resize Crysterm::Event::Resize.new
    w.tput.flush
    output.to_s[mark..].should_not contain "\e[2J"
  ensure
    w.try &.destroy
  end

  it "is shown again by Application#show" do
    app = Crysterm::Application.new
    w = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w.hide
    app.show w
    w.visible?.should be_true
  ensure
    w.try &.destroy
  end

  it "leaves an inline region once, on hide, not again when destroyed hidden" do
    output = IO::Memory.new
    w = Crysterm::Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
      width: 40, height: 4, alternate: false, default_quit_keys: false)
    w.repaint
    w.hide
    w.tput.flush
    mark = output.to_s.size
    w.destroy
    # No cursor parking (CUP) below a region the shell has written past.
    output.to_s[mark..].should_not match /\e\[\d+;\d+H/
  end
end
