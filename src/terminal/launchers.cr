module Crysterm
  # Support code for opening real terminal *windows/panes/sessions* and driving
  # them with a Crysterm `Screen`. A "launcher" is a registered recipe for one
  # backend program — how to instruct it to run a given command in a new window.
  #
  # Backends are NOT only GUI emulators (xterm, kitty, alacritty, …). They also
  # include multiplexers and special terminals (tmux, screen, yakuake, …), each
  # of which is told to open a new window/pane/session differently. Every known
  # backend has a registered recipe; an unknown name falls back to the common
  # `<name> -e <command>` convention (the xterm style).
  #
  # The handshake env var (`CRYSTERM_WINDOW_HELPER`) is *inlined into the command*
  # (via `env VAR=… <exe>`) rather than passed through the process environment.
  # This is essential for multiplexers: a running tmux/screen server does not
  # inherit our process's environment, so only an inlined value reaches the
  # helper. It works identically for GUI emulators.
  module Terminal
    # A registered way to launch a command in a new terminal window/pane/session.
    class Launcher
      getter name : String

      # (inner, cols, rows, title) -> full argv. `inner` is the command to run
      # in the new window, already env-inlined by `Terminal.spawn_window`.
      @command : Proc(Array(String), Int32, Int32, String?, Array(String))

      # Optional fully-custom spawner for backends that are not a single argv
      # (e.g. yakuake, driven over D-Bus). When set, it is used instead of
      # `@command` + `Process.new`. Receives the same (env-inlined) `inner`.
      @spawn : Proc(Array(String), Int32, Int32, String?, Process)?

      def initialize(@name, @command, @spawn = nil)
      end

      # Whether this backend's binary is present on the system.
      def available? : Bool
        !!Process.find_executable(@name)
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
      # gnome-terminal forks to a server (process-based teardown unreliable; the
      # in-window helper exiting still closes the tab — see Window#close).
      Launcher.flags("gnome-terminal", run_flag: "--",
        geometry: ->(c : Int32, r : Int32) { ["--geometry=#{c}x#{r}"] },
        title: ->(t : String) { ["--title", t] }),

      # ── Multiplexers ──
      # tmux: a new window in the current session when run from inside tmux
      # ($TMUX set), otherwise a new detached session. The command's args follow
      # the tmux options directly.
      Launcher.new("tmux", ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
        argv = ENV["TMUX"]? ? ["tmux", "new-window"] : ["tmux", "new-session", "-d"]
        argv += ["-n", t] if t
        argv + inner
      end),
      # screen: a new window in the current session (best run from inside screen).
      Launcher.new("screen", ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
        argv = ["screen"]
        argv += ["-t", t] if t
        argv + inner
      end),

      # ── Special / D-Bus driven ──
      # yakuake (KDE drop-down terminal): add a session, then run the command in
      # it over D-Bus. Best-effort; lifecycle relies on the helper/socket (the
      # qdbus call itself returns immediately and is not the window's process).
      Launcher.new("yakuake",
        ->(inner : Array(String), c : Int32, r : Int32, t : String?) { inner },
        ->(inner : Array(String), c : Int32, r : Int32, t : String?) do
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
        if t = ENV["TERMINAL"]?
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
      Launcher.flags(base, run_flag: "-e")
    end
  end
end
