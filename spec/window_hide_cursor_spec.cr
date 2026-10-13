require "./spec_helper"

# A hidden window (`Window#hide`) has handed its terminal back, and with it
# the cursor: `#leave` resets the terminal's cursor shape and color, changes
# made while hidden reach only the window's `Cursor` (nothing is written over
# the shell's screen), and `#show` applies the window's cursor again, custom
# shape included, where `#leave` used to reset the `Cursor` itself to a block.
# A suspend (`Crysterm.suspend_terminals`) gives the shell the terminal's own
# cursor too and the resume takes the window's back.

private def cursor_window(output : IO::Memory) : Crysterm::Window
  w = Crysterm::Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
  w.screen.hardware_cursor = true
  w.tput.features.cursor_style = true
  w.tput.features.cursor_color = true
  w
end

private def written_since(w : Crysterm::Window, output : IO::Memory, mark : Int32) : String
  w.tput.flush
  output.to_s[mark..]
end

describe "Window#hide and the cursor" do
  it "keeps a custom cursor across hide and show, writing nothing while hidden" do
    output = IO::Memory.new
    w = cursor_window output
    w.set_cursor_shape Tput::CursorShape::Line
    w.cursor_color = "red"
    w.repaint

    mark = output.size
    w.hide
    out = written_since w, output, mark
    out.should contain "\e[0 q"
    out.should contain "\e]112\a"

    mark = output.size
    w.set_cursor_shape Tput::CursorShape::Underline
    w.cursor_color = "#0000ff"
    w.hide_cursor
    w.show_cursor
    written_since(w, output, mark).should eq ""
    w.cursor.shape.should eq Tput::CursorShape::Underline

    mark = output.size
    w.show
    out = written_since w, output, mark
    out.should contain "\e[4 q"
    out.should contain "\e]12;#0000ff\a"
  ensure
    w.try &.destroy
  end

  it "keeps a cursor the app hid hidden across hide and show" do
    output = IO::Memory.new
    w = cursor_window output
    w.hide_cursor
    w.hide
    w.show
    w.cursor.hidden?.should be_true
  ensure
    w.try &.destroy
  end

  it "gives the shell its own cursor while suspended and takes the window's back on resume" do
    output = IO::Memory.new
    w = cursor_window output
    w.set_cursor_shape Tput::CursorShape::Line
    w.repaint

    mark = output.size
    Crysterm.suspend_terminals
    written_since(w, output, mark).should contain "\e[0 q"

    mark = output.size
    Crysterm.resume_terminals
    written_since(w, output, mark).should contain "\e[6 q"
  ensure
    w.try &.destroy
  end
end
