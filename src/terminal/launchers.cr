module Crysterm
  # Support code for opening real terminal *windows/panes/sessions* and driving
  # them with a Crysterm `Window`. A "launcher" is a registered recipe for one
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

      def initialize(@name, @command, @spawn = nil)
      end

      # Whether this backend's binary is present on the system.
      def available? : Bool
        !!Process.find_executable(@name)
      end

      # Builds the argv this launcher would exec for *inner* without spawning
      # anything — a dry-run of `#launch` for inspection/testing. Returns `nil`
      # for backends driven by a custom spawner (no single argv).
      def argv_for(inner : Array(String), cols : Int32, rows : Int32, title : String?) : Array(String)?
        return nil if @spawn
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

    # The registry of known backends, in rough order of preference. The first
    # *available* one is used when none is requested (after honoring `$TERMINAL`).
    LAUNCHERS = [
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
        argv = Crysterm::Config.environment_tmux ? ["tmux", "new-window"] : ["tmux", "new-session", "-d"]
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
    # (auto-detect). Auto-detection honors `$TERMINAL` first, then the first
    # available registered backend.
    def self.resolve_launcher(launcher : Launcher | String | Nil) : Launcher?
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
        LAUNCHERS.find &.available?
      end
    end

    # Looks up a known launcher by (base)name; if unknown but present on the
    # system, returns a generic `<name> -e <command>` launcher (the xterm style).
    private def self.find_launcher(name : String) : Launcher?
      base = File.basename(name)
      if known = LAUNCHERS.find { |l| l.name == base }
        return known if known.available?
      end
      return nil unless Process.find_executable(name)
      # Build the fallback with the resolved spec (the literal `name`, which may
      # be an absolute path), not `base`, so `Process.new` execs exactly what
      # was validated instead of doing a PATH lookup on the basename.
      Launcher.flags(name, run_flag: "-e")
    end
  end
end
