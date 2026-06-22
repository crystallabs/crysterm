require "event_handler"
require "tput"

module Crysterm
  # Collection of all events used by Crysterm
  module Event
    include EventHandler

    # Events currently unused have been commented. Uncomment on first use.

    # Emitted when widget is attached to a screen directly or somewhere in its ancestry
    event Attach, object : EventHandler

    # Emitted when widget is detached from a screen directly or somewhere in its ancestry
    event Detach, object : EventHandler

    # Emitted when widget gains a new parent
    event Reparent, widget : Widget?

    # Emitted when widget is added to parent
    event Adopt, widget : Widget

    # Emitted when widget is removed from its current parent
    event Remove, widget : Widget

    # Emitted when Widget is destroyed
    event Destroy

    # Emitted when a child process backing a widget (e.g. `Widget::Terminal`'s
    # shell) exits. `code` is the process exit status, or `nil` if unknown.
    event Exit, code : Int32? = nil

    # Emitted when a `Screen` is bound to a freshly spawned terminal emulator
    # window (see `Screen.open`). `screen` is the screen now driving the window.
    event WindowOpened, screen : Crysterm::Screen

    # Emitted when the terminal emulator window backing a `Screen` goes away —
    # typically because the user closed it. The `Screen` itself is NOT destroyed
    # by default (it is only disconnected, keeping its widget tree intact), so a
    # handler may re-attach it to a new window via `Screen.open(into: screen)` or
    # tear it down with `screen.destroy`. `screen` is the affected screen.
    event WindowClosed, screen : Crysterm::Screen

    # Emitted when widget focuses. Requires terminal supporting the focus protocol.
    event Focus, el : Widget? = nil

    # Emitted when widget goes out of focus. Requires terminal supporting the focus protocol.
    event Blur, el : Widget? = nil

    # Emitted when widget scrolls
    event Scroll

    # # Emitted on some data
    # event Data, data : String

    # # Emitted on a warning event
    # event Warning, message : String

    # Emitted when screen is resized.
    event Resize, size : Tput::Namespace::Size? = nil

    # Emitted by a `Crysterm::Timer` on every tick. Widgets (and anything else)
    # subscribe to a shared timer to animate in lockstep off one clock.
    event Tick

    # Emitted when object is hidden
    event Hide

    # Emitted when object is shown
    event Show

    # Emitted at the beginning of rendering/drawing.
    event PreRender

    # Emitter at the end or rendering/drawing.
    event Rendered

    # # event PostRender

    # # Emitted at the end of drawing. Currently disabled/unused.
    # # event Draw

    # Emitted after Widget's content is defined
    event SetContent

    # Emitted after Widget's content is parsed
    event ParsedContent

    # Emitted on mouse click
    event Click

    # Emitted on button press
    event Press

    # Emitted on checkbox checked
    event Check, value : Bool

    # Emitted on checkbox unchecked
    event UnCheck, value : Bool

    # Emitted when Widget's position is changed
    event Move

    # Emitted on something being completed (e.g. progressbar reaching 100%)
    event Complete

    # Emitted on something being reset (e.g. a `Widget::Form` being reset to
    # its initial state, or a progressbar reset to 0%).
    event Reset

    # Emitted on value submitted (e.g. in text forms)
    event Submit, value : String

    # Emitted when a `Widget::Form` is submitted. Carries the collected
    # name => value pairs of all input children (see `Widget::Form#submit`).
    event SubmitData, data : Hash(String, String)

    # Emitted on value canceled (e.g. in text forms)
    event Cancel, value : String

    # Emitted by `Widget::FileManager` when the current directory changes.
    # `path` is the directory just entered; `cwd` is the directory left behind.
    event ChangeDir, path : String, cwd : String

    # Emitted by `Widget::FileManager` when a (non-directory) file is selected.
    event OpenFile, path : String

    # Emitted by `Widget::FileManager` after its listing is (re)loaded, and by
    # any widget that reloads its contents from an external source.
    event Refresh

    event Action, value : String

    # Emitted on creation of a list item
    event CreateItem

    # Emitted on addition of a list item to list
    event AddItem
    # Emitted on insertion of a list item at a given position
    event InsertItem
    # Emitted on removal of a list item
    event RemoveItem
    # Emitted on re-set/re-definition of list items
    event SetItem
    # :ditto:
    event SetItems

    event CancelItem, item : Widget::Box, index : Int32
    event ActionItem, item : Widget::Box, index : Int32

    # Event emitted when a new log line intended for `Widget::Log` is issued
    event Log, text : String
    # NOTE In Blessed, this is called `log` and `Widget::Log`. It's been renamed
    # in Crysterm not to conflict with `Log` coming from logger.

    # Emitted on selection of an item in list
    event SelectItem, item : Widget::Box, index : Int32

    # Emitted by `Widget::ListBar` when a tab/command is selected via
    # `#select_tab` (e.g. through `auto_command_keys`). `item` is the command's
    # element box (`nil` if the index is out of range), `index` its position.
    event SelectTab, item : Widget::Box?, index : Int32

    # Emitted when an Action is Triggered
    event Triggered

    # Emitted when a Widget or Action are hovered
    event Hovered

    # # event Key, key : ::Tput::Key

    # Individual key events emitted on specific key presses. This is used when
    # the caller does not want to listen for everything on `Event::KeyPress` (i.e.
    # all keypresses), but when they want explicit keys like
    # `Event::KeyPress::CtrlQ`.
    class KeyPress < EventHandler::Event
      property char : Char
      property key : ::Tput::Key?
      property sequence : Array(Char)
      property? accepted : Bool = false

      def initialize(char, @key = nil, @sequence = [char])
        @char = char
      end

      # Accepts event and causes it to stop propagating.
      def accept
        @accepted = true
      end

      # Ignores event and causes it to continue propagating.
      def ignore
        @accepted = false
      end

      # Whether this keypress is the conventional "activate" gesture — Enter or
      # Space — used by buttons, checkboxes and similar to fire their action.
      # (Space arrives as a printable `char` with a nil `key`; Enter as a `key`.)
      def activates? : Bool
        @char == ' ' || @key == ::Tput::Key::Enter
      end

      # This macro takes all enum members from Tput::Key
      # and creates a `KeyPress::<member>` event for them,
      # such as `Event::KeyPress::CtrlQ`.
      #
      # This is done as a convenience, so that users would
      # not have to listen for all keypresses and then
      # manually check for particular keys every time.
      KEYS = {} of ::Tput::Key => self.class
      {% for m in ::Tput::Key.constants %}
        class {{m.id}} < self; end
        KEYS[ ::Tput::Key::{{m.id}} ] = {{m.id}}
      {% end %}
    end

    # Emitted on any mouse activity (button press/release, motion, wheel).
    #
    # This is the single, normalized mouse event for Crysterm. It is emitted
    # both for mouse reports parsed from the terminal (xterm SGR/X10, via
    # `Tput`) and for events coming from the Linux console `gpm` daemon — both
    # sources are converted to a common `::Tput::Mouse::Event` and dispatched
    # through `Screen#dispatch_mouse`, so listeners need not care about origin.
    #
    # It is emitted on the `Screen` and, when the pointer is over a registered
    # clickable `Widget`, on that widget as well (see `Screen#widget_at`).
    class Mouse < EventHandler::Event
      # The underlying normalized mouse event.
      property mouse : ::Tput::Mouse::Event

      property? accepted : Bool = false

      def initialize(@mouse)
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

      def shift? : Bool
        @mouse.shift?
      end

      def meta? : Bool
        @mouse.meta?
      end

      def ctrl? : Bool
        @mouse.ctrl?
      end

      # Accepts event and causes it to stop propagating.
      def accept
        @accepted = true
      end

      # Ignores event and causes it to continue propagating.
      def ignore
        @accepted = false
      end
    end

    # Hover events. These carry the same payload as `Mouse` (they subclass it)
    # but signal pointer *hovering* transitions rather than raw activity.
    #
    # They are emitted on a `Widget` only — and only on the **topmost** widget
    # under the pointer, mirroring how a click is dispatched (see
    # `Screen#dispatch_mouse`). A widget that is occluded by another does not
    # receive hover events; if it needs to react while in the background, it can
    # listen for the screen-level `Mouse` event (emitted for every mouse event)
    # and do its own hit-testing.
    #
    # Listeners subscribe to the specific transition they care about, e.g.
    # `widget.on(Event::MouseOver) { ... }`.

    # Emitted once when the pointer enters a widget (hover in).
    class MouseOver < Mouse; end

    # Emitted on pointer motion while staying over the same widget (hovering).
    class MouseMove < Mouse; end

    # Emitted once when the pointer leaves a widget (hover out).
    class MouseOut < Mouse; end

    # Drag-and-drop events.
    #
    # A single, input-agnostic gesture (see `Crysterm::DragSession`). Source
    # events (`DragStart`/`Drag`/`DragEnd`) fire on the dragged widget; target
    # events (`DragEnter`/`DragOver`/`DragLeave`/`Drop`) fire on the widget
    # currently under the pointer (mouse sensor) or focused (keyboard sensor).
    # Both mouse and keyboard drive the same events, so a widget written once is
    # draggable/droppable by either input.
    #
    # Every event carries the live `session`, whose `data` holds the MIME-typed
    # payload and the negotiated `DragAction`. A drop target opts in by
    # `accept`ing a `DragEnter`/`DragOver`; only an accepted target receives a
    # `Drop`.
    abstract class DragEvent < EventHandler::Event
      getter session : ::Crysterm::DragSession
      property? accepted : Bool = false

      def initialize(@session)
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
