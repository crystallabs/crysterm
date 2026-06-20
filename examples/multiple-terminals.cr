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
#    and then FREE the terminal by replacing its shell with an inert parker:
#
#        $ tty                  # e.g. prints /dev/pts/7
#        $ exec sleep infinity  # replace the shell; the device is now idle
#
#    This step is essential, not optional. A terminal delivers its input to
#    whatever process is reading it, and its mode (raw/cooked, echo) is set by
#    its *foreground* process. If an interactive shell is still sitting at its
#    prompt there, that shell — not us — owns the input: when we enable mouse
#    reporting the terminal starts emitting `\e[<…M` reports, and the shell's
#    readline reads and echoes them as literal text while fighting us for every
#    keystroke. `exec sleep infinity` removes the shell (no readline, no job
#    control, no cooked-mode resets), leaving us the sole reader and owner of
#    the terminal's mode. (`kill` that sleep when you're done with the window.)
#
# 2. From your main terminal, launch this program, passing the device path(s)
#    of the freed terminals as arguments:
#
#        crystal examples/multiple-terminals.cr -- /dev/pts/7 /dev/pts/9
#
#    When paths are given, ONLY those terminals are driven (not the launching
#    one); each becomes an independent screen. With NO arguments, the program
#    drives just the terminal it was launched from.
#
# 3. Press `q` (or Ctrl-Q) in ANY of the terminals to tear all of them down and
#    exit. Each terminal is restored to its normal buffer on the way out.

# Interactive shells (and other programs that drive a terminal via a line
# editor) compete with us for input and keep resetting the terminal mode, which
# is exactly what makes mouse/key events leak instead of being consumed. We
# refuse to take over a terminal whose foreground process is one of these.
SHELL_NAMES = %w[sh bash zsh dash ash ksh fish tcsh csh busybox]

# Returns the command name of the *foreground* process of the terminal at
# *path*, or nil if none can be determined.
#
# NOTE we cannot use `tcgetpgrp(2)` here: the kernel only lets a process query
# the foreground process group of its *own* controlling terminal, so it returns
# -1/ENOTTY for any other terminal. Instead we go through `/proc`: find a
# process that has this terminal open, read that terminal's foreground process
# group (`tpgid`, the 6th field after the `(comm)` column in `/proc/PID/stat`),
# and report that group leader's name.
def foreground_comm(path : String) : String?
  real = File.realpath(path) rescue path
  Dir.each_child("/proc") do |entry|
    next unless entry.to_i?

    attached = {0, 1, 2}.any? do |n|
      link = File.readlink("/proc/#{entry}/fd/#{n}") rescue nil
      link == path || link == real
    end
    next unless attached

    stat = File.read("/proc/#{entry}/stat") rescue next
    idx = stat.rindex(')')
    next unless idx
    # After "(comm)": state ppid pgrp session tty_nr tpgid ...
    tpgid = stat[(idx + 1)..].split[5]?.try(&.to_i?)
    next unless tpgid && tpgid > 0

    return File.read("/proc/#{tpgid}/comm").strip rescue nil
  end
  nil
end

# Returns `nil` if the terminal at *path* is ready for us to take over, or a
# short human-readable reason why it is not. The intended ready state is an
# inert parker (e.g. `exec sleep infinity`); a live interactive shell is not.
def terminal_blocker(path : String) : String?
  comm = foreground_comm(path)
  return nil unless comm # nothing identifiable competing -> ready
  return "an interactive shell (#{comm}) is running there" if SHELL_NAMES.includes?(comm)
  nil
end

module MultipleTerminals
  include Crysterm

  # One descriptor per terminal we want to drive. `input`/`output` are nil for
  # the launching terminal (Screen defaults to STDIN/STDOUT); otherwise they are
  # the opened TTY. NOTE these are two *separate* file descriptors on the same
  # device: Crysterm assumes input and output are distinct fds (its defaults are
  # `STDIN`/`STDOUT`), and a key-reader fiber blocks on input while the renderer
  # writes to output concurrently — sharing one handle for both leaves the
  # output silent. So we mirror STDIN/STDOUT: open the device once read-only and
  # once write-only.
  record Terminal,
    label : String,
    input : IO::FileDescriptor?,
    output : IO::FileDescriptor?

  terminals = [] of Terminal

  if ARGV.empty?
    # No terminals specified: drive only the terminal we were launched from.
    # (input/output nil -> Screen uses its STDIN/STDOUT defaults.)
    terminals << Terminal.new("terminal #1 (this one)", nil, nil)
    STDERR.puts "No TTYs specified; driving only the launching terminal."
    STDERR.puts "Pass one or more TTY paths to drive those instead, e.g.:"
    STDERR.puts "  crystal #{PROGRAM_NAME} -- /dev/pts/7 /dev/pts/9"
    STDERR.puts "(Run `tty` in another terminal to find its device path.)"
  else
    # Terminals specified: drive *only* the given TTYs, not the launching one.
    # Open and validate every one first, collecting any that are not ready, and
    # refuse to start (taking over none of them) unless ALL are ready.
    not_ready = [] of {String, String}

    ARGV.each_with_index do |path, i|
      unless File.exists?(path)
        STDERR.puts "No such terminal device: #{path}"
        exit 1
      end
      # Two separate fds on the same TTY, just like STDIN/STDOUT.
      input = File.open(path, "r")
      output = File.open(path, "w")
      unless input.tty? && output.tty?
        STDERR.puts "#{path} is not a terminal."
        exit 1
      end
      # Readiness gate: nothing else may own this terminal's input/mode.
      if reason = terminal_blocker(path)
        not_ready << {path, reason}
        next
      end
      terminals << Terminal.new("terminal ##{i + 1} (#{path})", input, output)
    end

    unless not_ready.empty?
      STDERR.puts "Refusing to start — these target terminals are not ready:"
      not_ready.each { |(path, reason)| STDERR.puts "  #{path} — #{reason}" }
      STDERR.puts
      STDERR.puts "Free each one first by replacing its shell with an inert parker."
      STDERR.puts "In each of those terminals, run:"
      STDERR.puts
      STDERR.puts "    exec sleep infinity"
      STDERR.puts
      STDERR.puts "then re-run this program. (`exec` removes the shell so it stops"
      STDERR.puts "reading input and managing the terminal's mode.)"
      exit 1
    end
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
  screens.each do |screen|
    screen.render
    screen.listen
  end

  sleep
end
