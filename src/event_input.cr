require "event_handler"
require "tput"

require "./event"

module Crysterm
  # The class-based input events: keyboard (`Key`/`KeyPress`/`KeyRelease`),
  # mouse (`Mouse` and the hover subclasses), and drag-and-drop (the
  # `DragEvent` family). Defined as classes (not via the `event` macro) so they
  # can include `Acceptable` (defined in `event.cr`, required above) and carry
  # richer behavior; the declarative `event ...` definitions stay in
  # `event.cr`.
  module Event
    # Base class for keyboard events. Carries the key identity (`char` / `key` /
    # `sequence`) and, when the terminal speaks an enhanced keyboard protocol
    # (kitty / modifyOtherKeys), the rich `key_event` plus flat accessors for its
    # details (`#alt?`, `#modifier_key`, …) — all `nil`/`false` for legacy
    # (un-enhanced) input, which the flat `#key`/`#char` cannot express.
    #
    # The concrete events are `KeyPress` (a press or auto-repeat) and
    # `KeyRelease` (a release). Subscribe to:
    #
    #   * `Event::KeyPress`         — presses/repeats only (the common case)
    #   * `Event::KeyRelease`       — releases only
    #   * `Event::Key`              — both (every key transition)
    #   * `Event::KeyPress::CtrlQ`  — one specific key press
    abstract class Key < EventHandler::Event
      include Acceptable

      property char : Char
      property key : ::Tput::Key?

      # Raw input sequence backing `#sequence`. Nilable and materialized lazily so
      # that plain typing — where the parser passes no array — allocates nothing
      # unless a consumer actually reads `#sequence`.
      @sequence : Array(Char)?

      # The rich keyboard event when an enhanced protocol is active, else `nil`.
      getter key_event : ::Tput::KeyEvent?

      def initialize(@char, @key = nil, @sequence : Array(Char)? = nil, @key_event = nil)
      end

      # Raw input sequence for this key, materializing and caching the
      # one-element `[@char]` fallback on first read.
      def sequence : Array(Char)
        @sequence ||= [@char]
      end

      # Sets the raw input sequence.
      def sequence=(sequence : Array(Char)) : Array(Char)
        @sequence = sequence
      end

      # The active modifiers, or `nil` for legacy input.
      def modifiers : ::Tput::Modifiers?
        @key_event.try &.mods
      end

      # The Unicode codepoint, when the terminal reported one (kitty `u`-form);
      # `nil` otherwise.
      def codepoint : Int32?
        @key_event.try &.codepoint
      end

      # The standalone modifier key this event represents (`:left_alt`,
      # `:right_ctrl`, …), or `nil` if it is not a lone modifier. A `KeyRelease`
      # whose `#modifier_key` is set is the "modifier tapped" gesture.
      def modifier_key : Symbol?
        @key_event.try &.modifier_key
      end

      # Whether this is an auto-repeat rather than an initial transition.
      def repeat? : Bool
        !!@key_event.try(&.repeat?)
      end

      {% for m in %w[shift alt ctrl super hyper meta] %}
        # Whether the {{ m.id }} modifier was held.
        def {{ m.id }}? : Bool
          !!@key_event.try(&.{{ m.id }}?)
        end
      {% end %}
    end

    # A key press (or auto-repeat). `Event::KeyPress` is *always* a press —
    # releases are delivered as `KeyRelease` — so press handlers need no guard.
    class KeyPress < Key
      # Whether this keypress is the conventional "activate" gesture — Enter or
      # Space — used by buttons, checkboxes and similar to fire their action.
      # (Space arrives as a printable `char` with a nil `key`; Enter as a `key`.)
      def activates? : Bool
        @char == ' ' || @key == ::Tput::Key::Enter
      end

      # Builds a `KeyPress` from a human-readable key label, as shown in
      # command bars and menus: a single printable character (`"s"`), a caret
      # chord (`"^X"` → `Tput::Key::CtrlX`), or a conventional key name —
      # `"Spc"`/`"Space"`, `"Enter"`/`"Ret"`, `"Tab"`, `"Esc"`, `"Up"`,
      # `"Dn"`/`"Down"`, `"Left"`, `"Right"`, `"PgUp"`, `"PgDn"`, `"Home"`,
      # `"End"`, `"Del"`, `"F1"`…`"F12"`. Returns `nil` for anything it does
      # not recognize. Lets a clickable key hint (e.g. `Pine::KeyMenu`) replay
      # itself through the same handlers as the physical key.
      def self.parse(label : String) : self?
        case label
        when "Spc", "Space" then new ' ', nil
        when "Enter", "Ret" then new '\r', ::Tput::Key::Enter
        when "Tab"          then new '\t', ::Tput::Key::Tab
        when "Esc"          then new '\e', ::Tput::Key::Escape
        when "Up"           then new '\0', ::Tput::Key::Up
        when "Dn", "Down"   then new '\0', ::Tput::Key::Down
        when "Left"         then new '\0', ::Tput::Key::Left
        when "Right"        then new '\0', ::Tput::Key::Right
        when "PgUp"         then new '\0', ::Tput::Key::PageUp
        when "PgDn"         then new '\0', ::Tput::Key::PageDown
        when "Home"         then new '\0', ::Tput::Key::Home
        when "End"          then new '\0', ::Tput::Key::End
        when "Del"          then new '\0', ::Tput::Key::Delete
        else
          if label.size == 1 && label[0].printable?
            new label[0], nil
          elsif label.size == 2 && label[0] == '^' && label[1].ascii_letter?
            key = ::Tput::Key.parse? "Ctrl#{label[1].upcase}"
            key.try { |k| new '\0', k }
          elsif label =~ /\AF(\d{1,2})\z/
            key = ::Tput::Key.parse? "F#{$1}"
            key.try { |k| new '\0', k }
          end
        end
      end

      # A `KeyPress::<member>` event per `Tput::Key` member (e.g.
      # `Event::KeyPress::CtrlQ`), so a listener can subscribe to one key rather
      # than to every keypress.
      KEYS = {} of ::Tput::Key => self.class
      {% for m in ::Tput::Key.constants %}
        class {{ m.id }} < self; end
        KEYS[ ::Tput::Key::{{ m.id }} ] = {{ m.id }}
      {% end %}
    end

    # A key release. Only emitted when an enhanced keyboard protocol with event
    # reporting is active (`Window#enable_keyboard_protocol(level: :events)`);
    # otherwise the terminal never reports releases and this never fires.
    class KeyRelease < Key
    end

    # Emitted on any mouse activity (button press/release, motion, wheel).
    #
    # The single, normalized mouse event for Crysterm: terminal reports (xterm
    # SGR/X10, via `Tput`) and Linux console `gpm` events are both converted to a
    # common `::Tput::Mouse::Event`, so listeners need not care about origin.
    #
    # Emitted on the `Window` and, when the pointer is over a registered clickable
    # `Widget`, on that widget as well.
    class Mouse < EventHandler::Event
      include Acceptable

      # The underlying normalized mouse event.
      property mouse : ::Tput::Mouse::Event

      # The widget this event is being delivered to, or `nil` for the
      # window-level emit. What `#local_x`/`#local_y` resolve against.
      getter target : Widget?

      def initialize(@mouse, @target = nil)
      end

      # Re-targets this (pooled) event at a new underlying `mouse` report (and
      # delivery *target*) and clears any prior `accept`, so one event can be
      # reused across dispatches instead of allocating per report. A handler
      # that *retains* the event will see its fields mutate on the next report —
      # copy anything to be kept past the handler's own invocation.
      def reset(@mouse : ::Tput::Mouse::Event, @target : Widget? = nil) : self
        @accepted = false
        self
      end

      # The kind of action (Down/Up/Move/WheelUp/WheelDown).
      def action : ::Tput::Mouse::Action
        @mouse.action
      end

      # Which button the event pertains to.
      def button : ::Tput::Mouse::Button
        @mouse.button
      end

      # 0-based column.
      def x : Int32
        @mouse.x
      end

      # 0-based row.
      def y : Int32
        @mouse.y
      end

      # 0-based sub-cell pixel column, when SGR-Pixels (DEC 1016) reporting is
      # active; `nil` otherwise. `x`/`y` still carry the cell coordinates, so
      # pixel-aware widgets can read `px`/`py` without disturbing the rest.
      def px : Int32?
        @mouse.px
      end

      # 0-based sub-cell pixel row; see `#px`.
      def py : Int32?
        @mouse.py
      end

      # 0-based column relative to the target widget's content origin (inside
      # its border/padding) — the column of the pointer within the widget's
      # `contents_rect`, saving every click handler the
      # `e.x - (lpos.xi + ileft)` derivation. Falls back to the absolute `#x`
      # for the window-level emit (no widget target).
      def local_x : Int32
        t = @target
        return x unless t
        x - t.painted_content_origin[0]
      end

      # 0-based row relative to the target widget's content origin; see
      # `#local_x`.
      def local_y : Int32
        t = @target
        return y unless t
        y - t.painted_content_origin[1]
      end

      def shift? : Bool
        @mouse.shift?
      end

      def meta? : Bool
        @mouse.meta?
      end

      def ctrl? : Bool
        @mouse.ctrl?
      end
    end

    # Hover events. Same payload as `Mouse` (they subclass it), but signalling
    # pointer *hovering* transitions rather than raw activity.
    #
    # Emitted on a `Widget` only, and only on the **topmost** widget under the
    # pointer, as a click is. An occluded widget gets no hover events; to react
    # while in the background it must listen for the screen-level `Mouse` event
    # and hit-test itself.
    #
    # Listeners subscribe to the specific transition they care about, e.g.
    # `widget.on(Event::MouseEnter) { ... }`.

    # Emitted once when the pointer enters a widget (hover in).
    class MouseEnter < Mouse; end

    # Emitted on pointer motion while staying over the same widget (hovering).
    class MouseMove < Mouse; end

    # Emitted once when the pointer leaves a widget (hover out).
    class MouseLeave < Mouse; end

    # Drag-and-drop events — a single, input-agnostic gesture.
    #
    # Source events (`DragStart`/`Drag`/`DragEnd`) fire on the dragged widget;
    # target events (`DragEnter`/`DragOver`/`DragLeave`/`Drop`) fire on the widget
    # currently under the pointer (mouse sensor) or focused (keyboard sensor).
    # Mouse and keyboard drive the same events, so a widget written once is
    # draggable/droppable by either.
    #
    # Every event carries the live `session`, whose `data` holds the MIME-typed
    # payload and the negotiated `DragAction`. A drop target opts in by
    # `accept`ing a `DragEnter`/`DragOver`; only an accepted target receives a
    # `Drop`.
    abstract class DragEvent < EventHandler::Event
      include Acceptable

      getter session : ::Crysterm::DragSession

      def initialize(@session)
      end

      # Re-points this (pooled) event at a new *session* and clears any prior
      # `accept`, so one instance can be reused across the per-motion `Drag`/
      # `DragOver` emits instead of allocating per report. Mirrors
      # `Event::Mouse#reset`: a handler that *retains* the event will see its
      # fields mutate on the next motion — copy anything kept past the handler.
      def reset(@session : ::Crysterm::DragSession) : self
        @accepted = false
        self
      end

      # The drag's typed payload + negotiated action.
      def data : ::Crysterm::DragData
        @session.data
      end

      # The widget being dragged.
      def source : ::Crysterm::Widget
        @session.source
      end

      # Current anchor column (absolute cell coordinate).
      def x : Int32
        @session.x
      end

      # Current anchor row (absolute cell coordinate).
      def y : Int32
        @session.y
      end

      # For a drop target: accept this drag, optionally pinning the action
      # (e.g. `e.accept Crysterm::DragAction::Copy`).
      def accept(action : ::Crysterm::DragAction? = nil)
        @accepted = true
        @session.data.accept action
      end

      # Withdraws acceptance, the inverse of `#accept`. Must clear the *session's*
      # accepted flag too, not just the event's as `Acceptable#ignore` does:
      # delivery of `Drop` is decided from `session.data.accepted?`, so otherwise
      # a target that accepts then withdraws would still get the drop.
      def ignore
        @accepted = false
        @session.data.reject
      end
    end

    # Fired on the source when a drag begins. A transfer source should populate
    # `data` (payload + supported actions) here; a reposition source needs no
    # payload and just records its grab offset.
    class DragStart < DragEvent; end

    # Fired on the source on each motion (mouse) or arrow-key nudge (keyboard).
    class Drag < DragEvent; end

    # Fired on a widget when the drag enters it (it becomes the candidate target).
    class DragEnter < DragEvent; end

    # Fired on the current target on each motion while the drag stays over it.
    class DragOver < DragEvent; end

    # Fired on a widget when the drag leaves it.
    class DragLeave < DragEvent; end

    # Fired on the target on release — only if it accepted the drag.
    class Drop < DragEvent; end

    # Fired on the source after the gesture ends (drop or cancel). `dropped?`
    # reports whether a target accepted; combined with `data.action` it tells a
    # Move source to remove the original vs a Copy source to keep it.
    class DragEnd < DragEvent
      property? dropped : Bool = false
    end
  end
end
