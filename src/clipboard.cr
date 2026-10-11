require "./application"

module Crysterm
  class Application
    # The application clipboard ↔ `QClipboard`. `#text=` copies to the active
    # window's terminal via OSC-52; `#request` asks for the system selection
    # (reply lands asynchronously on that device's input), so `#text` is cached.
    #
    # How a copy leaves the process — and where a paste may come from — is
    # the `#mode` (`Mode`): the terminal's OSC 52 escape by default, which
    # the terminal forwards to the system clipboard where it allows that; a
    # system command (`pbcopy`, `wl-copy`, `xclip`, `xsel`, `tmux`) where it
    # does not — tmux and screen without passthrough, SSH, terminals that
    # ignore or garble OSC 52 — found on the PATH the first time it is
    # needed; or nothing, the in-process mirror alone. Qt's platform plugin
    # decides this per platform; a terminal application has to be told.
    class Clipboard
      # Where a copy goes and where a paste may come from.
      enum Mode
        # OSC 52 to the copying window's terminal (`Window#copy`), which may
        # forward it to the system clipboard; a paste reads the in-process
        # mirror, refreshed by the terminal's OSC 52 reply to `#request` where
        # the terminal answers one. The default.
        Terminal
        # A system command: a copy is piped to `#copy_command`, a paste read
        # from `#paste_command`'s output, synchronously, the way neovim's
        # clipboard providers work. Without a command found, a copy stays in
        # the mirror and `#error` says so.
        Command
        # The in-process mirror only: copy and paste work within the
        # application, nothing leaves it and nothing is read from outside.
        Internal
      end

      # Runs a command (an argv) with *input* on its standard input and
      # returns its standard output, or nil when it could not be started or
      # failed. Replaceable (`#command_runner=`) so specs observe the
      # commands without running them.
      alias CommandRunner = Proc(Array(String), String, String?)

      # The copy and paste commands `Command` mode looks for on the PATH, in
      # order of preference, each with the environment variable that says
      # its display is there (nil for none needed): macOS's `pbcopy`,
      # Wayland's `wl-copy`, X11's `xclip` and `xsel`, and inside tmux its
      # buffer, which tmux forwards to the outer terminal's clipboard
      # (`load-buffer -w`). The paste command is the copy command's own
      # counterpart, so only the copy command is looked for.
      COMMAND_CANDIDATES = [
        {nil, ["pbcopy"], ["pbpaste"]},
        {"WAYLAND_DISPLAY", ["wl-copy"], ["wl-paste", "--no-newline"]},
        {"DISPLAY", ["xclip", "-selection", "clipboard"], ["xclip", "-selection", "clipboard", "-o"]},
        {"DISPLAY", ["xsel", "--clipboard", "--input"], ["xsel", "--clipboard", "--output"]},
        {"TMUX", ["tmux", "load-buffer", "-w", "-"], ["tmux", "save-buffer", "-"]},
      ]

      # The mirror: the last text copied or received (`#text`).
      @text : String = ""
      # `{copy, paste}` once detected or set (`#copy_command`).
      @commands : {Array(String)?, Array(String)?}?

      def initialize(@app : Application)
      end

      # How copies leave the process and pastes come in (`Mode`).
      property mode : Mode = Mode::Terminal

      # Runs `Command` mode's commands; the default runs them as processes
      # (`.run_command`).
      property command_runner : CommandRunner = ->(argv : Array(String), input : String) { Clipboard.run_command(argv, input) }

      # Why the last `Command` mode copy or paste did not reach the system —
      # no command found, or the command failed — or nil while the last one
      # went through. The text still went to, or came from, the mirror.
      getter error : String?

      # Rich payload of the last copy, when it came from a rich-text source; the
      # formatted counterpart of `#text`. Non-nil only while the *most recent*
      # copy was rich: any plain `#text=` clears it, so a paste that prefers the
      # fragment can never resurrect stale formatting over newer plain text.
      getter fragment : TextDocumentFragment?

      # The copy and paste commands `Command` mode uses, as argument vectors:
      # the first of `COMMAND_CANDIDATES` found on the PATH when first asked
      # for (`.detect_commands`), or whatever the application sets. Nil when
      # none is found, or to go without.
      def copy_command : Array(String)?
        commands[0]
      end

      def copy_command=(argv : Array(String)?) : Array(String)?
        @commands = {argv, paste_command}
        argv
      end

      def paste_command : Array(String)?
        commands[1]
      end

      def paste_command=(argv : Array(String)?) : Array(String)?
        @commands = {copy_command, argv}
        argv
      end

      # Last value set or received. Refreshed automatically when an OSC-52 read
      # reply arrives — and, in `Command` mode, from the paste command on
      # every read, so a paste sees what the system holds now.
      def text : String
        if @mode.command?
          @error = nil
          if argv = paste_command
            if value = @command_runner.call(argv, "")
              refresh_from_terminal value
            else
              @error = "#{argv[0]} failed"
            end
          else
            @error = "no clipboard command found"
          end
        end
        @text
      end

      # Sets the clipboard text and copies it to the active window's terminal.
      def text=(value : String) : String
        copy value
      end

      # Like `#text=`, but the OSC-52 write goes to *window*'s own device (the
      # app-active window when nil). Input routing is per-device without
      # reordering `@windows`, so `active_window` (just `@windows.last`) may be
      # a window on a *different* terminal than the copying widget's — the copy
      # would then clobber the wrong terminal's clipboard. Callers that know
      # their surface should pass it; the in-process mirror (`#text`) stays
      # app-wide either way. In `Command` mode the text goes to the copy
      # command instead; in `Internal` mode it stays in the mirror.
      def copy(text : String, window : Window? = nil) : String
        @fragment = nil
        @text = text
        @error = nil
        case @mode
        in .terminal? then (window || @app.active_window).try &.copy(text)
        in .command?  then run_copy_command text
        in .internal? then nil
        end
        text
      end

      # Rich copy: *fragment* for in-process rich paste, plus its plain-text
      # rendering for the terminal (OSC-52 carries text only, so the system
      # clipboard degrades to plain). *window* routes the device write like
      # the plain `#copy`.
      def copy(fragment : TextDocumentFragment, text : String, window : Window? = nil) : Nil
        copy text, window
        @fragment = fragment
      end

      # Refreshes the cached text from an OSC-52 *read* reply that just arrived on
      # a device's input. Does NOT re-copy to the terminal — the value came
      # *from* it. Called by `Window#handle_input` on a `Tput::InputEvent#clipboard`.
      # An unchanged value is our own copy echoed back, so the rich payload
      # stays valid; anything else is a fresher external copy and drops it.
      def refresh_from_terminal(value : String) : String
        @fragment = nil unless value == @text
        @text = value
      end

      # Asynchronously requests the system clipboard from *window*'s device
      # (the active window's when nil; OSC-52). The reply arrives later on that
      # device's input. Pass the requesting widget's own window so the query
      # goes to the terminal the user is actually interacting with (see
      # `#copy`). In the other modes the answer is at hand — the paste
      # command's output, or the mirror — and *window* hears it at once, as
      # the same `Event::ClipboardChanged` the terminal's reply arrives as.
      def request(window : Window? = nil) : Nil
        window ||= @app.active_window
        if @mode.terminal?
          window.try &.request_clipboard
        else
          window.try &.emit Crysterm::Event::ClipboardChanged.new text
        end
      end

      # Runs *argv* with *input* on its standard input; its standard output,
      # or nil when the command is not there or exits with a failure.
      def self.run_command(argv : Array(String), input : String) : String?
        output = IO::Memory.new
        status = Process.run(argv[0], argv[1..], input: IO::Memory.new(input), output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s : nil
      rescue IO::Error
        nil
      end

      # The first of `COMMAND_CANDIDATES` on the PATH whose display, when it
      # needs one, is there: `{copy, paste}`, or `{nil, nil}`.
      def self.detect_commands : {Array(String)?, Array(String)?}
        COMMAND_CANDIDATES.each do |env, copy, paste|
          next if env && !ENV[env]?.presence
          return {copy, paste} if Process.find_executable(copy[0])
        end
        {nil, nil}
      end

      private def commands : {Array(String)?, Array(String)?}
        @commands ||= Clipboard.detect_commands
      end

      private def run_copy_command(text : String) : Nil
        if argv = copy_command
          @error = "#{argv[0]} failed" unless @command_runner.call(argv, text)
        else
          @error = "no clipboard command found"
        end
      end
    end
  end
end
