require "base64"

module Crysterm
  # Device-side OSC escape-sequence transport — the small set of "tell the
  # terminal something / ask it something" operations that are pure `tput`/IO on
  # one tty: the OSC-52 system clipboard (write + read-back), OSC 7 working
  # directory, and OSC 9;4 progress. They belong on the device (`Screen`) for the
  # same reason the input-mode toggles do; the owning `Window` delegates them
  # (see the `delegate … to: @screen` block in `window.cr`).
  #
  # The `Application#clipboard` facade (≈ `QGuiApplication::clipboard()`) talks to
  # the active window's device through these. The async OSC-52 *read* reply still
  # arrives as an `Event::Paste` (Tput surfaces it that way), so wiring
  # `clipboard.text` to refresh on it is a separate follow-up — see the plan.
  class Screen
    # OSC 52: copies *text* to the terminal clipboard *selection* (`"c"`
    # clipboard, `"p"` primary). Works over SSH/tmux; ignored where unsupported.
    def copy(text : String, selection : String = "c") : Nil
      tput.set_clipboard text, selection
    end

    # OSC 52: asks the terminal for the clipboard *selection*. The contents
    # arrive asynchronously as an `Event::Paste` (so it works during the input
    # loop). Many terminals disable clipboard *reads* for security, in which case
    # no event arrives.
    def request_clipboard(selection : String = "c") : Nil
      tput.request_clipboard selection
    end

    # Outbound interop: copy *text* to the system clipboard via OSC 52, the one
    # channel that reliably crosses to other apps from inside a terminal (it
    # degrades to a no-op where the terminal does not support it). This is how a
    # cross-app "transfer" is realistically delivered — see `DragData`.
    def copy_to_clipboard(text : String) : Nil
      tput.sel_data "c", Base64.strict_encode(text)
    end

    # OSC 7: reports *path* to the terminal as the current working directory, so
    # terminals that track it ("open new tab/split here", titles) follow along.
    # *host* is the URI host (empty = local). Routed through tput (tmux-safe);
    # ignored where unsupported.
    def report_cwd(path : String, host : String = "") : Nil
      tput.report_cwd path, host
    end

    # OSC 9;4: drives the terminal's progress indicator (taskbar / tab badge).
    # *state*: 0 = clear, 1 = normal (show *progress*, 0–100), 2 = error,
    # 3 = indeterminate, 4 = warning. Ignored where unsupported.
    def progress(progress : Int32 = 0, state : Int32 = 1) : Nil
      tput.progress progress, state
    end
  end
end
