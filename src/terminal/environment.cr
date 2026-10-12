module Crysterm
  module Terminal
    # Where the program runs, as far as opening another terminal window goes:
    # whether this is a session in which `Window.open` has somewhere to put
    # one (`.graphical?`), and which emulator is showing the program
    # (`.current_emulator`), so a new window can be asked of the same program
    # rather than of whichever registered backend happens to be installed —
    # a kitty user gets another kitty window, not an xterm.
    #
    # Detection is by environment variable first, the way `Tput::Emulator`
    # identifies the terminal: multiplexers and emulators mark their children
    # (`TMUX`, `STY`, `TERM_PROGRAM`, `KITTY_WINDOW_ID`…). Inherited variables
    # can lie — a shell started from kitty that opened an xterm still carries
    # `KITTY_WINDOW_ID` — so the multiplexer and `TERM_PROGRAM` are read
    # first (set by the innermost program) and, when nothing marks the
    # environment, the chain of parent processes is walked for a known
    # emulator's process name (`.parent_emulator`), which cannot be inherited
    # wrongly. The names are the launchers' (`LAUNCHERS`), so a found emulator
    # resolves to its launcher directly (`.resolve_launcher`).

    # What `TERM_PROGRAM` values name, as launcher names where a launcher
    # exists. tmux sets it too, inside; the multiplexer check comes first
    # anyway.
    TERM_PROGRAMS = {
      "Apple_Terminal" => "terminal.app",
      "iTerm.app"      => "iterm2",
      "WezTerm"        => "wezterm",
      "ghostty"        => "ghostty",
      "kitty"          => "kitty",
      "Alacritty"      => "alacritty",
      "tmux"           => "tmux",
      "vscode"         => "vscode",
      "Hyper"          => "hyper",
      "WarpTerminal"   => "warp",
      "rio"            => "rio",
      "mintty"         => "mintty",
    }

    # Emulators that mark their children with a variable of their own, in the
    # order the marks are trusted. `VTE_VERSION` is set by every VTE-based
    # terminal (gnome-terminal, xfce4-terminal, tilix…); it stands for the
    # commonest one and is consulted after the parent processes, which name
    # the actual program.
    EMULATOR_VARIABLES = {
      "KITTY_WINDOW_ID"        => "kitty",
      "KITTY_PID"              => "kitty",
      "ALACRITTY_WINDOW_ID"    => "alacritty",
      "ALACRITTY_SOCKET"       => "alacritty",
      "WEZTERM_PANE"           => "wezterm",
      "WEZTERM_EXECUTABLE"     => "wezterm",
      "GHOSTTY_RESOURCES_DIR"  => "ghostty",
      "ITERM_SESSION_ID"       => "iterm2",
      "KONSOLE_VERSION"        => "konsole",
      "GNOME_TERMINAL_SCREEN"  => "gnome-terminal",
      "GNOME_TERMINAL_SERVICE" => "gnome-terminal",
      "XTERM_VERSION"          => "xterm",
      "TERMINATOR_UUID"        => "terminator",
      "WT_SESSION"             => "windows-terminal",
    }

    # Process names (`comm`: the executable's base name, cut to 15 characters
    # on Linux) of known emulators and multiplexers, for the parent walk.
    EMULATOR_PROCESSES = {
      "kitty"                 => "kitty",
      "alacritty"             => "alacritty",
      "wezterm-gui"           => "wezterm",
      "wezterm"               => "wezterm",
      "foot"                  => "foot",
      "footclient"            => "foot",
      "xterm"                 => "xterm",
      "konsole"               => "konsole",
      "st"                    => "st",
      "gnome-terminal-server" => "gnome-terminal",
      "gnome-terminal"        => "gnome-terminal",
      "tmux"                  => "tmux",
      "tmux: server"          => "tmux",
      "screen"                => "screen",
      "yakuake"               => "yakuake",
      "Terminal"              => "terminal.app",
      "iTerm2"                => "iterm2",
      "ghostty"               => "ghostty",
      "urxvt"                 => "urxvt",
      "urxvtd"                => "urxvt",
      "rxvt"                  => "rxvt",
      "xfce4-terminal"        => "xfce4-terminal",
      "tilix"                 => "tilix",
      "terminator"            => "terminator",
      "lxterminal"            => "lxterminal",
      "mate-terminal"         => "mate-terminal",
      "qterminal"             => "qterminal",
      "sakura"                => "sakura",
      "terminology"           => "terminology",
      "contour"               => "contour",
      "rio"                   => "rio",
      "zutty"                 => "zutty",
    }

    # How many parents the walk follows before giving up: a terminal is
    # rarely more than a shell, a multiplexer and a few programs away.
    PARENT_WALK_LIMIT = 24

    # Whether the program runs inside tmux or GNU screen, whose new windows
    # are windows too — the one kind that opens over SSH or on a console.
    def self.multiplexed? : Bool
      !!(Config.environment_tmux.presence || Config.environment_sty.presence)
    end

    # Whether a new terminal window can be opened here: on X11 or Wayland
    # (`DISPLAY`/`WAYLAND_DISPLAY` set), inside a multiplexer, or — on macOS,
    # where a GUI session sets neither — in a terminal emulator at all
    # (`.current_emulator`): a session on the console, over SSH or from a
    # service has no screen to put a window on. *ancestors* false skips the
    # parent-process walk (a controlled check reads the variables alone).
    def self.graphical?(ancestors : Bool = true) : Bool
      return true if multiplexed?
      return true if Config.environment_display.presence || Config.environment_wayland_display.presence
      {% if flag?(:darwin) %}
        return true if current_emulator(ancestors: ancestors)
      {% end %}
      false
    end

    # The terminal program showing this process, as a launcher name
    # (`"kitty"`, `"tmux"`, `"terminal.app"`…) or the program's lower-case
    # name when no launcher knows it (`"vscode"`), or nil when none can be
    # told. Inside tmux or screen the multiplexer is the answer: it is what a
    # new window is asked of. See the module comment for the order.
    def self.current_emulator(ancestors : Bool = true) : String?
      return "tmux" if Config.environment_tmux.presence
      return "screen" if Config.environment_sty.presence
      if program = Config.environment_term_program.presence
        return TERM_PROGRAMS[program]? || program.downcase
      end
      EMULATOR_VARIABLES.each { |variable, name| return name if ENV[variable]?.presence }
      if ancestors && (found = parent_emulator)
        return found
      end
      return "gnome-terminal" if ENV["VTE_VERSION"]?.presence
      nil
    end

    # The first known emulator among this process's ancestors, by process
    # name, or nil. Reads `/proc` where there is one, else asks `ps` (macOS,
    # the BSDs) one parent at a time; a process that cannot be read ends the
    # walk.
    def self.parent_emulator : String?
      pid = Process.ppid.to_i64
      PARENT_WALK_LIMIT.times do
        return if pid <= 1
        ppid, name = process_parent_and_name(pid) || return
        if found = emulator_process_name(name)
          return found
        end
        pid = ppid
      end
      nil
    end

    # The emulator a process named *comm* is, or nil. Linux cuts `comm` to
    # 15 characters, so a cut name matches the known name it begins.
    def self.emulator_process_name(comm : String) : String?
      comm = File.basename(comm)
      EMULATOR_PROCESSES[comm]? ||
        (comm.size == 15 ? EMULATOR_PROCESSES.find { |name, _| name.starts_with?(comm) }.try(&.[1]) : nil)
    end

    # The parent's pid and the process name of *pid*, or nil when it cannot
    # be read.
    private def self.process_parent_and_name(pid : Int64) : {Int64, String}?
      {% if flag?(:linux) %}
        stat = File.read("/proc/#{pid}/stat") rescue return
        # `pid (comm) state ppid …`; the name may hold spaces and parentheses,
        # so it ends at the last `)`.
        close = stat.rindex(')') || return
        open = stat.index('(') || return
        name = stat[open + 1...close]
        ppid = stat[close + 1..].split[1]?.try(&.to_i64?) || return
        {ppid, name}
      {% else %}
        output = IO::Memory.new
        status = Process.run("ps", ["-o", "ppid=,comm=", "-p", pid.to_s], output: output, error: Process::Redirect::Close) rescue return
        return unless status.success?
        line = output.to_s.strip
        ppid, _, name = line.partition(/\s+/)
        parent = ppid.to_i64? || return
        {parent, name.strip}
      {% end %}
    end

    # Why `Window.open` would fail here, in a sentence for the user, or nil
    # when a window can be opened: not a graphical session, or no backend to
    # open one with. What a program's New Window entry disables itself on.
    def self.window_refusal : String?
      return "not in a graphical session (no display, and not inside tmux or screen)" unless graphical?
      return "no terminal emulator found (tried $TERMINAL and: #{LAUNCHERS.map(&.name).join(", ")})" unless resolve_launcher(nil)
      nil
    end
  end
end
