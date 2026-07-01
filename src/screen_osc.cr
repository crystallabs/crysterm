require "base64"

module Crysterm
  # Device-side OSC escape-sequence transport: OSC-52 system clipboard (write +
  # read-back), OSC 7 working directory, and OSC 9;4 progress. These live on the
  # device (`Screen`), like the input-mode toggles; the owning `Window` delegates
  # to them (see `delegate … to: @screen` in `window.cr`).
  #
  # `Application#clipboard` (≈ `QGuiApplication::clipboard()`) talks to the active
  # window's device through these. The async OSC-52 read reply arrives as an
  # `Event::Paste`; wiring `clipboard.text` to refresh on it is a separate
  # follow-up.
  class Screen
    # OSC 52: copies *text* to the terminal clipboard *selection* (`"c"`
    # clipboard, `"p"` primary). Works over SSH/tmux; ignored where unsupported.
    def copy(text : String, selection : String = "c") : Nil
      tput.set_clipboard text, selection
    end

    # OSC 52: asks the terminal for the clipboard *selection*. The contents
    # arrive asynchronously as an `Event::Paste`. Many terminals disable
    # clipboard reads for security, in which case no event arrives.
    def request_clipboard(selection : String = "c") : Nil
      tput.request_clipboard selection
    end

    # Outbound interop: copy *text* to the system clipboard via OSC 52 (no-op
    # where unsupported). How a cross-app "transfer" gets delivered — see
    # `DragData`.
    def copy_to_clipboard(text : String) : Nil
      tput.sel_data "c", Base64.strict_encode(text)
    end

    # OSC 7: reports *path* to the terminal as the current working directory
    # (for "open new tab/split here", titles, etc). *host* is the URI host
    # (empty = local). Routed through tput (tmux-safe); ignored where unsupported.
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
