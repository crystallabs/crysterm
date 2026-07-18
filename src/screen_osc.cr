require "base64"

module Crysterm
  # Device-side OSC escape-sequence transport: OSC-52 system clipboard (write +
  # read-back), OSC 7 working directory, and OSC 9;4 progress. These live on the
  # device (`Screen`), like the input-mode toggles; the owning `Window`
  # delegates to them.
  #
  # `Application#clipboard` (≈ `QGuiApplication::clipboard()`) talks to the
  # active window's device through these.
  class Screen
    # OSC 52 selection target for `#copy`/`#request_clipboard`: the system
    # `ClipboardChanged` (default), or X11's `Primary` (middle-click) selection.
    # Serializes to OSC 52's single-letter "c"/"p" selection code.
    enum Selection
      Clipboard
      Primary
    end

    # OSC 52: copies *text* to the terminal clipboard *selection*. Works over
    # SSH/tmux; ignored where unsupported.
    #
    # Shares its implementation with `#copy_to_clipboard` (`tput.sel_data`,
    # which prefers the terminfo "Ms" extended capability and falls back to a
    # raw OSC 52 sequence) rather than `tput.set_clipboard`'s always-raw
    # sequence — the two used genuinely different transports before merging;
    # `#copy_to_clipboard` is kept as its own (still public — spec-observed)
    # method rather than folded away, since it predates *selection* and is
    # exercised directly.
    def copy(text : String, selection : Selection = :clipboard) : Nil
      copy_to_clipboard text, selection
    end

    # OSC 52: asks the terminal for the clipboard *selection*. The contents
    # arrive asynchronously as an `Event::Paste`. Many terminals disable
    # clipboard reads for security, in which case no event arrives.
    def request_clipboard(selection : Selection = :clipboard) : Nil
      tput.request_clipboard selection_code(selection)
    end

    # Outbound interop: copy *text* to the system clipboard via OSC 52 (no-op
    # where unsupported). How a cross-app "transfer" gets delivered. `#copy`'s
    # implementation (see its doc comment for why this stays separate).
    def copy_to_clipboard(text : String, selection : Selection = :clipboard) : Nil
      tput.sel_data selection_code(selection), Base64.strict_encode(text)
    end

    # Serializes a `Selection` to OSC 52's single-letter selection code.
    private def selection_code(selection : Selection) : String
      selection.primary? ? "p" : "c"
    end

    # OSC 7: reports *path* to the terminal as the current working directory
    # (for "open new tab/split here", titles, etc). *host* is the URI host
    # (empty = local). Routed through tput (tmux-safe); ignored where unsupported.
    def report_cwd(path : String, host : String = "") : Nil
      tput.report_cwd path, host
    end

    # State `#progress` reports the terminal's progress indicator in (OSC
    # 9;4), matching the `state` parameter of the underlying escape sequence.
    enum ProgressState
      Clear         # 0: clear the indicator
      Normal        # 1: show *value* (0-100)
      Error         # 2: error
      Indeterminate # 3: indeterminate (busy, no known percentage)
      Warning       # 4: warning/paused
    end

    # OSC 9;4: drives the terminal's progress indicator (taskbar / tab badge).
    # *value* is the 0-100 percentage shown while *state* is `Normal`.
    # Ignored where unsupported.
    def progress(value : Int32 = 0, state : ProgressState = :normal) : Nil
      tput.progress value, state.to_i
    end
  end
end
