require "./environment"

module Crysterm
  # Support code for opening real terminal *windows/panes/sessions* and driving
  # them with a Crysterm `Window` (the surface; the spawned window itself is a
  # `Terminal::EmulatorWindow`). A "launcher" is a registered recipe for one
  # backend program — how to instruct it to run a given command in a new window.
  #
  # Backends include GUI emulators (xterm, kitty, alacritty, …) as well as
  # multiplexers and special terminals (tmux, screen, yakuake, …), each told to
  # open a new window/pane/session differently. An unknown backend falls back
  # to the common `<name> -e <command>` convention (the xterm style).
  #
  # The handshake env var (`CRYSTERM_WINDOW_HELPER`) is inlined into the
  # command (via `env VAR=… <exe>`) rather than passed through the process
  # environment: a running tmux/window server does not inherit our process's
  # environment, so only an inlined value reaches the helper.
  module Terminal
    # A spawned window's frame on the desktop, `{x, y, width, height}` in
    # screen points from the top-left corner of the main display — what
    # `QWindow::frameGeometry` gives as a `QRect` (the window manager's
    # decorations included). Only some launchers can set or read it
    # (`Launcher#frame_geometry_supported?`).
    alias Frame = {Int32, Int32, Int32, Int32}

    # A registered way to launch a command in a new terminal window/pane/session.
    class Launcher
      getter name : String

      # (inner, cols, rows, title) -> full argv. `inner` is the command to run
      # in the new window, already env-inlined by `Terminal.spawn_window`.
      @command : Proc(Array(String), Int32, Int32, String?, Array(String))

      # Optional fully-custom spawner for backends that aren't a single argv
      # (e.g. yakuake, driven over D-Bus). Used instead of `@command` when set,
      # and receives the same env-inlined `inner`.
      @spawn : Proc(Array(String), Int32, Int32, String?, Process)?

      # Optional presence check for backends that are not a binary on the
      # PATH (a macOS application bundle, driven through `osascript`). When
      # unset, `#available?` looks the name up on the PATH.
      @available : Proc(Bool)?

      # Optional spawner that also puts the new window at a given frame
      # (`#launch` with `frame:`): the same arguments as `@spawn`, plus the
      # frame. Only backends that can place their windows have one.
      @placed_spawn : Proc(Array(String), Int32, Int32, String?, Frame, Process)?

      # Optional reader of a spawned window's frame, given the window's TTY
      # (what the in-window helper reported): nil when it cannot be read.
      @frame_reader : Proc(String, Frame?)?

      def initialize(@name, @command, @spawn = nil, @available = nil,
                     @placed_spawn = nil, @frame_reader = nil)
      end

      # Whether this backend can both place a new window at a frame
      # (`#launch` with `frame:`) and read a window's frame back
      # (`#frame_geometry`): Terminal.app and iTerm2 on macOS, through
      # AppleScript; no other backend.
      def frame_geometry_supported? : Bool
        !@placed_spawn.nil? && !@frame_reader.nil?
      end

      # The frame of the window this backend opened on *tty* (the device the
      # in-window helper reported) ↔ `QWindow::frameGeometry`, or nil when the
      # backend cannot tell or the window is gone. Slow where supported (an
      # `osascript` run, 100-300 ms): ask off the render path, at close, say.
      def frame_geometry(tty : String) : Frame?
        @frame_reader.try &.call(tty)
      end

      # Whether this backend is present on the system.
      def available? : Bool
        if check = @available
          check.call
        else
          !!Process.find_executable(@name)
        end
      end

      # Builds the argv this launcher would exec for *inner* without spawning
      # anything — a dry-run of `#launch` for inspection/testing. Returns `nil`
      # for backends driven by a custom spawner (no single argv).
      def argv_for(inner : Array(String), cols : Int32, rows : Int32, title : String?) : Array(String)?
        return if @spawn
        @command.call(inner, cols, rows, title)
      end

      # Launches *inner* (the env-inlined helper command) in a new window/pane,
      # returning the backing process. With *frame*, a backend that can place
      # its windows (`#frame_geometry_supported?`) puts the new one there,
      # sized by the frame rather than by *cols* and *rows*; every other
      # backend leaves the placement to the window manager.
      def launch(inner : Array(String), cols : Int32, rows : Int32, title : String?,
                 frame : Frame? = nil) : Process
        if frame && (placed = @placed_spawn)
          placed.call(inner, cols, rows, title, frame)
        elsif custom = @spawn
          custom.call(inner, cols, rows, title)
        else
          argv = @command.call(inner, cols, rows, title)
          Process.new(argv[0], argv[1..])
        end
      end

      # Builds a launcher for a flag-style backend (the common GUI-emulator
      # shape): `<name> <prefix...> <geometry...> <title...> <run_flag> <inner>`.
      def self.flags(name : String, prefix : Array(String) = [] of String,
                     run_flag : String? = nil,
                     geometry : Proc(Int32, Int32, Array(String))? = nil,
                     title : Proc(String, Array(String))? = nil) : Launcher
        cmd = ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
          argv = [name] + prefix
          geometry.try { |g| argv.concat g.call(c, r) }
          if tt = t
            title.try { |tf| argv.concat tf.call(tt) }
          end
          argv << run_flag if run_flag
          argv.concat inner
          argv
        end
        new(name, cmd)
      end
    end

    {% if flag?(:darwin) %}
      # ── macOS applications ──
      # Terminal.app and iTerm2 have no `-e`: they are told through
      # AppleScript (`osascript`) to run the command in a new window — the
      # helper `exec`ed over the shell, so the shell's exit is the helper's
      # and the window closes with it (Terminal.app keeps it open with
      # "[Process completed]" when the profile says so; the default profile
      # closes on a clean exit). The `osascript` process returns at once,
      # so the window's life is the helper's, as with gnome-terminal.
      # Terminal.app is always there; the others when their bundle is. First
      # in `LAUNCHERS` on macOS, where the PATH rarely has an emulator.
      MACOS_LAUNCHERS = [
        Launcher.new("terminal.app",
          ->(inner : Array(String), _c : Int32, _r : Int32, _t : String?) { inner },
          ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
            Process.new("osascript", ["-e", terminal_app_script(inner, c, r, t)])
          end,
          -> { File.exists?("/System/Applications/Utilities/Terminal.app") || File.exists?("/Applications/Utilities/Terminal.app") },
          ->(inner : Array(String), c : Int32, r : Int32, t : String?, f : Frame) do
            Process.new("osascript", ["-e", terminal_app_script(inner, c, r, t, f)])
          end,
          ->(tty : String) { read_frame terminal_app_frame_script(tty) }),
        # The command is typed into the new window's shell (`write text`),
        # as for Terminal.app, not given as the window's `command`: iTerm2
        # runs that one itself, split by its own rules and with no shell, so
        # the `exec` at its head would be looked up as a program.
        Launcher.new("iterm2",
          ->(inner : Array(String), _c : Int32, _r : Int32, _t : String?) { inner },
          ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
            Process.new("osascript", ["-e", iterm2_script(inner, c, r, t)])
          end,
          -> { application_bundle?("iTerm.app") },
          ->(inner : Array(String), c : Int32, r : Int32, t : String?, f : Frame) do
            Process.new("osascript", ["-e", iterm2_script(inner, c, r, t, f)])
          end,
          ->(tty : String) { read_frame iterm2_frame_script(tty) }),
        # Ghostty's macOS build has no `-e`, no `+new-window`, and a second
        # instance started by `open -n` with `--command=` shows no window the
        # helper can report from (tried 1.3.1): no launcher for it yet.
      ]
    {% else %}
      MACOS_LAUNCHERS = [] of Launcher
    {% end %}

    # The registry of known backends, in rough order of preference. The first
    # *available* one is used when none is requested (after honoring
    # `$TERMINAL` and the emulator the program runs in, `.resolve_launcher`).
    LAUNCHERS = MACOS_LAUNCHERS + [
      # ── GUI emulators ──
      Launcher.flags("kitty",
        geometry: ->(c : Int32, r : Int32) { ["-o", "initial_window_width=#{c}c", "-o", "initial_window_height=#{r}c"] }),
      Launcher.flags("alacritty", run_flag: "-e",
        geometry: ->(c : Int32, r : Int32) { ["--dimensions", c.to_s, r.to_s] },
        title: ->(t : String) { ["--title", t] }),
      Launcher.flags("wezterm", prefix: ["start"], run_flag: "--"),
      Launcher.flags("foot",
        geometry: ->(c : Int32, r : Int32) { ["--window-size-chars=#{c}x#{r}"] },
        title: ->(t : String) { ["-T", t] }),
      Launcher.flags("xterm", run_flag: "-e",
        geometry: ->(c : Int32, r : Int32) { ["-geometry", "#{c}x#{r}"] },
        title: ->(t : String) { ["-T", t] }),
      Launcher.flags("konsole", run_flag: "-e"),
      Launcher.flags("st", run_flag: "-e",
        geometry: ->(c : Int32, r : Int32) { ["-g", "#{c}x#{r}"] },
        title: ->(t : String) { ["-t", t] }),
      # gnome-terminal forks to a server, so process-based teardown is
      # unreliable; the in-window helper exiting still closes the tab.
      Launcher.flags("gnome-terminal", run_flag: "--",
        geometry: ->(c : Int32, r : Int32) { ["--geometry=#{c}x#{r}"] },
        title: ->(t : String) { ["--title", t] }),

      # ── Multiplexers ──
      # tmux: a new window in the current session when run from inside tmux
      # ($TMUX set), otherwise a new detached session.
      Launcher.new("tmux", ->(inner : Array(String), _c : Int32, _r : Int32, t : String?) do
        argv = Crysterm::Config.environment_tmux.presence ? ["tmux", "new-window"] : ["tmux", "new-session", "-d"]
        argv += ["-n", t] if t
        argv + inner
      end),
      # GNU screen: a new window in the current session (best run from inside screen).
      Launcher.new("screen", ->(inner : Array(String), _c : Int32, _r : Int32, t : String?) do
        argv = ["screen"]
        argv += ["-t", t] if t
        argv + inner
      end),

      # ── Special / D-Bus driven ──
      # yakuake (KDE drop-down terminal): add a session, then run the command
      # over D-Bus. Best-effort; the qdbus call returns immediately and is not
      # the window's process, so lifecycle relies on the helper/socket.
      Launcher.new("yakuake",
        ->(inner : Array(String), _c : Int32, _r : Int32, _t : String?) { inner },
        ->(inner : Array(String), _c : Int32, _r : Int32, _t : String?) do
          Process.run("qdbus", ["org.kde.yakuake", "/yakuake/sessions", "addSession"]) rescue nil
          cmdstr = inner.map { |a| Process.quote(a) }.join(" ")
          Process.new("qdbus", ["org.kde.yakuake", "/yakuake/sessions", "runCommand", cmdstr])
        end),
    ]

    # Resolves the launcher to use. Accepts a `Launcher`, a backend name, or nil
    # (auto-detect). Auto-detection honors `$TERMINAL` first, then the
    # emulator the program itself runs in (`.current_emulator`: a new window
    # of the same program, as a desktop's "new window" would open), then the
    # first available registered backend.
    def self.resolve_launcher(launcher : Launcher | String?) : Launcher?
      case launcher
      when Launcher
        launcher
      when String
        find_launcher(launcher)
      else
        if t = Crysterm::Config.environment_terminal
          name = t.split.first? || t
          if found = find_launcher(name)
            return found
          end
        end
        if (current = current_emulator) && (found = find_launcher(current))
          return found
        end
        LAUNCHERS.find &.available?
      end
    end

    # The AppleScript the `terminal.app` launcher runs: *inner* typed into a
    # new Terminal.app window (`do script`), the tab titled *title* and the
    # window sized *cols* by *rows* where the application allows it. With
    # *frame*, the window is then put there (`set bounds`), which sizes it
    # too.
    def self.terminal_app_script(inner : Array(String), cols : Int32, rows : Int32, title : String?,
                                 frame : Frame? = nil) : String
      String.build do |s|
        s << "tell application \"Terminal\"\n"
        s << "  set t to do script " << applescript_string(shell_command(inner)) << "\n"
        s << "  set custom title of t to " << applescript_string(title) << "\n" if title
        s << "  try\n"
        s << "    set w to first window whose selected tab is t\n"
        s << "    set number of columns of w to " << cols << "\n"
        s << "    set number of rows of w to " << rows << "\n"
        s << "  end try\n"
        if frame
          s << "  try\n"
          s << "    set bounds of (first window whose selected tab is t) to " << applescript_bounds(frame) << "\n"
          s << "  end try\n"
        end
        s << "end tell\n"
      end
    end

    # The AppleScript the `iterm2` launcher runs: a new window on the default
    # profile, *inner* typed into its session (`write text`), named *title*
    # and sized *cols* by *rows*. With *frame*, the window is then put there
    # (`set bounds`), which sizes it too.
    def self.iterm2_script(inner : Array(String), cols : Int32, rows : Int32, title : String?,
                           frame : Frame? = nil) : String
      String.build do |s|
        s << "tell application \"iTerm2\"\n"
        s << "  set w to (create window with default profile)\n"
        s << "  tell current session of w\n"
        s << "    write text " << applescript_string(shell_command(inner)) << "\n"
        s << "    try\n"
        s << "      set name to " << applescript_string(title) << "\n" if title
        s << "      set columns to " << cols << "\n"
        s << "      set rows to " << rows << "\n"
        s << "    end try\n"
        s << "  end tell\n"
        if frame
          s << "  try\n"
          s << "    set bounds of w to " << applescript_bounds(frame) << "\n"
          s << "  end try\n"
        end
        s << "end tell\n"
      end
    end

    # The AppleScript that reads the frame of the Terminal.app window whose
    # tab runs on *tty*: its `bounds` (`left, top, right, bottom`), or
    # nothing when no tab has that device. Asks nothing of an application
    # that is not running, so reading never starts Terminal.app.
    def self.terminal_app_frame_script(tty : String) : String
      String.build do |s|
        s << "if application \"Terminal\" is running then\n"
        s << "  tell application \"Terminal\"\n"
        s << "    repeat with w in windows\n"
        s << "      try\n"
        s << "        repeat with t in tabs of w\n"
        s << "          if tty of t is " << applescript_string(tty) << " then return bounds of w\n"
        s << "        end repeat\n"
        s << "      end try\n"
        s << "    end repeat\n"
        s << "  end tell\n"
        s << "end if\n"
      end
    end

    # The AppleScript that reads the frame of the iTerm2 window one of whose
    # sessions runs on *tty*: its `bounds`, or nothing when no session has
    # that device or iTerm2 is not running (it is not started to ask).
    def self.iterm2_frame_script(tty : String) : String
      String.build do |s|
        s << "if application \"iTerm2\" is running then\n"
        s << "  tell application \"iTerm2\"\n"
        s << "    repeat with w in windows\n"
        s << "      try\n"
        s << "        repeat with t in tabs of w\n"
        s << "          repeat with s in sessions of t\n"
        s << "            if tty of s is " << applescript_string(tty) << " then return bounds of w\n"
        s << "          end repeat\n"
        s << "        end repeat\n"
        s << "      end try\n"
        s << "    end repeat\n"
        s << "  end tell\n"
        s << "end if\n"
      end
    end

    # The frame *output* of a frame script names (`osascript` prints a
    # rectangle as `left, top, right, bottom`), or nil when it names none.
    def self.parse_bounds(output : String) : Frame?
      parts = output.split(',').map(&.strip.to_i?)
      return unless parts.size == 4
      left, top, right, bottom = parts
      return unless left && top && right && bottom && right > left && bottom > top
      {left, top, right - left, bottom - top}
    end

    # Why `Window.open(frame:)` cannot place a window here and
    # `Window#frame_geometry` cannot read one, in a sentence for the user,
    # or nil when they can: the backend `.resolve_launcher` picks for
    # *launcher* is not one that can (only Terminal.app and iTerm2, on
    # macOS), or there is none. What a program's "remember window
    # positions" entry disables itself on.
    def self.frame_geometry_refusal(launcher : Launcher | String? = nil) : String?
      backend = resolve_launcher(launcher)
      return "no terminal emulator found to open windows with" unless backend
      return if backend.frame_geometry_supported?
      "#{backend.name} cannot place its windows or report where they are (only Terminal.app and iTerm2 on macOS can)"
    end

    # How long `.read_frame` waits for its answer. An application that is
    # busy, or one waiting on a dialog, leaves an Apple event unanswered for
    # two minutes, AppleScript's own timeout: the window closing would wait
    # as long.
    FRAME_READ_TIMEOUT = 3.seconds

    # Runs the frame *script* through `osascript` (*command*, the script its
    # last argument) and reads its answer, or nil when it fails, names no
    # window, or gives none within *timeout*, when it is killed.
    def self.read_frame(script : String, command : Array(String) = ["osascript", "-e"],
                        timeout : Time::Span = FRAME_READ_TIMEOUT) : Frame?
      output = IO::Memory.new
      process = Process.new(command[0], command[1..] + [script], output: output, error: Process::Redirect::Close)
      done = Channel(Process::Status).new 1
      spawn(name: "Crysterm::Terminal frame reader") { done.send process.wait }
      select
      when status = done.receive
        parse_bounds output.to_s if status.success?
      when timeout(timeout)
        process.signal Signal::KILL rescue nil
        nil
      end
    rescue
      nil
    end

    # *frame* (`{x, y, width, height}`) as an AppleScript `bounds` rectangle,
    # `{left, top, right, bottom}`.
    private def self.applescript_bounds(frame : Frame) : String
      x, y, w, h = frame
      "{#{x}, #{y}, #{x + w}, #{y + h}}"
    end

    # *inner* as one shell command line, for the backends that take a string
    # rather than an argv (AppleScript's `do script`): `exec`ed, so the shell
    # the emulator starts is replaced by the helper and the window closes
    # when the helper exits.
    private def self.shell_command(inner : Array(String)) : String
      "exec " + inner.map { |a| Process.quote(a) }.join(" ")
    end

    # *text* as an AppleScript string literal.
    private def self.applescript_string(text : String) : String
      "\"" + text.gsub("\\", "\\\\").gsub("\"", "\\\"") + "\""
    end

    # Whether the macOS application *bundle* (`"iTerm.app"`) is installed, in
    # the system's or the user's Applications folder.
    private def self.application_bundle?(bundle : String) : Bool
      File.exists?(File.join("/Applications", bundle)) ||
        File.exists?(File.join(Path.home.to_s, "Applications", bundle))
    end

    # Looks up a known launcher by (base)name; if unknown but present on the
    # system, returns a generic `<name> -e <command>` launcher (the xterm style).
    private def self.find_launcher(name : String) : Launcher?
      base = File.basename(name)
      if known = LAUNCHERS.find { |l| l.name == base }
        return known if known.available?
      end
      return unless Process.find_executable(name)
      # Build the fallback with the resolved spec (the literal `name`, which may
      # be an absolute path), not `base`, so `Process.new` execs exactly what
      # was validated instead of doing a PATH lookup on the basename.
      Launcher.flags(name, run_flag: "-e")
    end
  end
end
