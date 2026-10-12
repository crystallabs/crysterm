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

      def initialize(@name, @command, @spawn = nil, @available = nil)
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
      # returning the backing process.
      def launch(inner : Array(String), cols : Int32, rows : Int32, title : String?) : Process
        if custom = @spawn
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
            script = String.build do |s|
              s << "tell application \"Terminal\"\n"
              s << "  set t to do script " << applescript_string(shell_command(inner)) << "\n"
              s << "  set custom title of t to " << applescript_string(t) << "\n" if t
              s << "  try\n"
              s << "    set w to first window whose selected tab is t\n"
              s << "    set number of columns of w to " << c << "\n"
              s << "    set number of rows of w to " << r << "\n"
              s << "  end try\n"
              s << "end tell\n"
            end
            Process.new("osascript", ["-e", script])
          end,
          -> { File.exists?("/System/Applications/Utilities/Terminal.app") || File.exists?("/Applications/Utilities/Terminal.app") }),
        Launcher.new("iterm2",
          ->(inner : Array(String), _c : Int32, _r : Int32, _t : String?) { inner },
          ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
            script = String.build do |s|
              s << "tell application \"iTerm2\"\n"
              s << "  set w to (create window with default profile command " << applescript_string(shell_command(inner)) << ")\n"
              s << "  try\n"
              s << "    tell current session of w\n"
              s << "      set name to " << applescript_string(t) << "\n" if t
              s << "      set columns to " << c << "\n"
              s << "      set rows to " << r << "\n"
              s << "    end tell\n"
              s << "  end try\n"
              s << "end tell\n"
            end
            Process.new("osascript", ["-e", script])
          end,
          -> { application_bundle?("iTerm.app") }),
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
