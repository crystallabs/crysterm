require "../src/crysterm"

# Controlling MULTIPLE terminals from a single program.
#
# A `Screen` already owns everything that makes a terminal a terminal: its own
# `input`/`output` IO, its own `Tput` (control sequences + capabilities), its
# own alternate-screen buffer, and its own key/render/resize fibers. So driving
# several terminals at once needs no special machinery — you just create one
# `Screen` per terminal, each bound to a different TTY device.
#
# HOW TO RUN
# ----------
# 1. Open one or more *extra* terminal windows. In each, find its device path
#    and park its shell so it stops reading the keyboard (otherwise the shell
#    would steal the input this program wants to read):
#
#        $ tty            # e.g. prints /dev/pts/7
#        $ sleep 100000   # park this terminal; Ctrl-C here when you're done
#
# 2. From your main terminal, launch this program, passing the device path(s)
#    of the *other* terminals as arguments:
#
#        crystal examples/multiple-terminals.cr -- /dev/pts/7 /dev/pts/9
#
#    The terminal you launch from becomes the first screen (via STDIN/STDOUT);
#    each path you pass becomes an additional, independently-controlled screen.
#
# 3. Press `q` (or Ctrl-Q) in ANY of the terminals to tear all of them down and
#    exit. Each terminal is restored to its normal buffer on the way out.

module MultipleTerminals
  include Crysterm
  RETAIN = [] of IO::FileDescriptor

  # One descriptor per terminal we want to drive. `input`/`output` are nil for
  # the launching terminal (Screen defaults to STDIN/STDOUT); otherwise they are
  # the opened TTY. NOTE these are two *separate* file descriptors on the same
  # device: Crysterm assumes input and output are distinct fds (its defaults are
  # `STDIN.dup`/`STDOUT.dup`), and a key-reader fiber blocks on input while the
  # renderer writes to output concurrently — sharing one handle for both leaves
  # the output silent. So we mirror STDIN/STDOUT: open the device once read-only
  # and once write-only.
  record Terminal,
    label : String,
    input : IO::FileDescriptor?,
    output : IO::FileDescriptor?

  # The terminal we were launched from is always screen #1.
  terminals = [Terminal.new("terminal #1 (this one)", nil, nil)]

  # Every extra ARGV entry is a TTY device path -> one more screen.
  ARGV.each_with_index do |path, i|
    unless File.exists?(path)
      STDERR.puts "No such terminal device: #{path}"
      exit 1
    end
    # Two separate fds on the same TTY, just like STDIN/STDOUT.
    input = File.open(path, "r")
    output = File.open(path, "w")
    RETAIN << input << output
    unless input.tty? && output.tty?
      STDERR.puts "#{path} is not a terminal."
      exit 1
    end
    terminals << Terminal.new("terminal ##{i + 2} (#{path})", input, output)
  end

  if terminals.size == 1
    STDERR.puts "Only the launching terminal is in use. Pass extra TTY paths to"
    STDERR.puts "drive more, e.g.:  crystal #{PROGRAM_NAME} -- /dev/pts/7"
    STDERR.puts "(Run `tty` in another terminal to find its device path.)"
  end

  # Build one Screen per terminal. Each Screen independently switches *its* TTY
  # to the alternate buffer and starts its own fibers.
  screens = terminals.map do |t|
    screen =
      if (input = t.input) && (output = t.output)
        Screen.new title: t.label, input: input, output: output
      else
        Screen.new title: t.label
      end

    Widget::Box.new \
      parent: screen,
      top: "center",
      left: "center",
      width: 40,
      height: 7,
      content: "{center}This is {bold}#{t.label}{/bold}.\n\n" \
               "It is driven by the same process as\nall the other terminals.\n\n" \
               "Press q in any terminal to quit.{/center}",
      parse_tags: true,
      style: Style.new(fg: "white", bg: "blue", border: true)

    screen
  end

  # A single quit path shared by every screen: destroy them all (restoring each
  # terminal) and exit. Guarded so the first `q` wins and the rest are no-ops.
  quitting = false
  quit = -> {
    return if quitting
    quitting = true
    screens.each &.destroy
    exit 0
  }

  screens.each do |screen|
    screen.on(Event::KeyPress) do |e|
      quit.call if e.char == 'q' || e.key == Tput::Key::CtrlQ
    end
  end

  # A little proof of life: every second, label each box with a per-terminal
  # tick so you can see all terminals updating concurrently and independently.
  screens.each_with_index do |screen, i|
    box = screen.children.first.as(Widget::Box)
    spawn do
      tick = 0
      loop do
        sleep 1.second
        tick += 1
        box.set_label " tick #{tick} "
        screen.render
      end
    end
  end

  # Start the input listeners and paint the first frame on every terminal, then
  # park the main fiber so all the per-screen fibers keep running. (`Screen#exec`
  # does render+listen+sleep for a single screen; with several screens we fan the
  # render+listen out ourselves and sleep just once here.)
  GC.collect
  screens.each do |screen|
    screen.render
    screen.listen
  end

  sleep
end
