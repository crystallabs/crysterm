require "./application"

module Crysterm
  class Application
    # The application clipboard ↔ `QClipboard`. `#text=` copies to the active
    # window's terminal via OSC-52; `#request` asks for the system selection
    # (reply lands asynchronously on that device's input), so `#text` is cached.
    class Clipboard
      def initialize(@app : Application)
      end

      # Last value set or received. Refreshed automatically when an OSC-52 read
      # reply arrives.
      getter text : String = ""

      # Rich payload of the last copy, when it came from a rich-text source; the
      # formatted counterpart of `#text`. Non-nil only while the *most recent*
      # copy was rich: any plain `#text=` clears it, so a paste that prefers the
      # fragment can never resurrect stale formatting over newer plain text.
      getter fragment : TextDocumentFragment?

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
      # app-wide either way.
      def copy(text : String, window : Window? = nil) : String
        @fragment = nil
        @text = text
        (window || @app.active_window).try &.copy(text)
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
      # `#copy`).
      def request(window : Window? = nil) : Nil
        (window || @app.active_window).try &.request_clipboard
      end
    end
  end
end
