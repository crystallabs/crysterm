require "./spec_helper"

# Drives the real device input fiber (`Screen#start_input` -> `tput.listen`)
# over an in-process pipe. Yields {writer, window, screen}.
private def r3_live_input(&)
  reader, writer = IO.pipe
  screen = Crysterm::Screen.new(
    input: reader, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
  win = Crysterm::Window.new(screen: screen, default_quit_keys: false)
  app = Crysterm::Application.new
  app.add win

  begin
    yield writer, win, screen
  ensure
    screen.stop_input
    writer.close rescue nil
    reader.close rescue nil
  end
end

private def r3_type(writer : IO, text : String) : Nil
  writer.write text.to_slice
  writer.flush
end

describe "Screen#stop_input" do
  it "loses no input event across a stop_input -> start_input cycle" do
    r3_live_input do |writer, win, screen|
      seen = [] of Char
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      r3_type writer, "a"
      wait_until { seen.size >= 1 }

      # The first fiber is parked in its read here.
      screen.stop_input
      screen.start_input

      "bcde".each_char do |c|
        r3_type writer, c.to_s
        wait_until { seen.last == c }
      end
      seen.should eq ['a', 'b', 'c', 'd', 'e']
    end
  end

  it "ends the parked read, so the stopped fiber consumes nothing" do
    r3_live_input do |writer, win, screen|
      seen = [] of Char
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      r3_type writer, "a"
      wait_until { seen.size >= 1 }

      screen.stop_input
      wait_until { !screen.tput.listening? }

      # Typed while stopped: still there for a synchronous read of the input.
      r3_type writer, "x"
      screen.input.read_char.should eq 'x'
      seen.should eq ['a']
    end
  end

  it "delivers input that arrived while stopped to the next start_input, in order" do
    r3_live_input do |writer, win, screen|
      seen = [] of Char
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      screen.stop_input
      r3_type writer, "x"

      screen.start_input
      r3_type writer, "k"
      wait_until { seen.size >= 2 }
      seen.should eq ['x', 'k']
    end
  end

  it "keeps a fiber stopped before it first ran from reading" do
    r3_live_input do |writer, win, screen|
      seen = [] of Char
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      screen.stop_input
      screen.start_input

      "abc".each_char do |c|
        r3_type writer, c.to_s
        wait_until { seen.last? == c }
      end
      seen.should eq ['a', 'b', 'c']
    end
  end

  it "loses nothing when a key handler stops and restarts input" do
    r3_live_input do |writer, win, screen|
      seen = [] of Char
      win.on(Crysterm::Event::KeyPress) do |e|
        seen << e.char
        if e.char == 'a'
          screen.stop_input
          screen.start_input
        end
      end

      screen.start_input
      # One write: `b` and `c` are read ahead together with `a`.
      r3_type writer, "abc"
      wait_until { seen.size >= 3 }
      seen.should eq ['a', 'b', 'c']
    end
  end
end

describe "an ESC-prefixed key from the terminal" do
  it "arrives as a key press with Alt held" do
    r3_live_input do |writer, win, screen|
      presses = [] of Crysterm::Event::KeyPress
      win.on(Crysterm::Event::KeyPress) { |e| presses << e }

      screen.start_input
      r3_type writer, "\e1"
      wait_until { presses.size >= 1 }
      presses[0].codepoint.should eq '1'.ord
      presses[0].alt?.should be_true
      presses[0].key.should be_nil
    end
  end
end
