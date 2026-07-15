require "event_handler"
require "tput"

module Crysterm
  # Collection of all events used by Crysterm.
  #
  # ## Naming
  #
  # Event names follow the stage of the action they report, which also keeps
  # them aligned with Qt (Qt names event *classes* as nouns — `QResizeEvent` —
  # and *signals* in the past tense — `valueChanged`):
  #
  # * **`Pre`-prefixed / `AboutTo`-prefixed** — emitted *before* the action, so a
  #   handler can still act on the old state (`PreRender`, `AboutToQuit`).
  #   Use `AboutTo` where Qt has an established signal of that exact name
  #   (`aboutToQuit`, `aboutToShow`, `aboutToHide`); `Pre` otherwise. Qt has no
  #   `Pre`-prefixed signals — for pipeline stages it uses `beforeX`/`afterX`
  #   (`beforeRendering`/`afterRendering`), which `PreRender`/`Rendered` mirrors.
  # * **Noun** — a discrete occurrence, emitted as it happens (`Click`, `Move`,
  #   `Resize`, `Paste`). These are Crysterm's analogue of Qt's event classes.
  # * **Past tense** — a notification that state has *already* changed, emitted
  #   after the mutation, and carrying the new value where one applies
  #   (`Rendered`, `ValueChanged`, `TextChanged`, `Toggled`). This is the form to
  #   use for any property-change signal; it matches Qt's `xChanged` contract.
  #
  # A property-change event must therefore be past tense and emitted *after* the
  # assignment, guarded so it only fires on an actual change.
  #
  # Events currently unused have been commented. Uncomment on first use.
  module Event
    include EventHandler

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

    # Emitted when a `Window` is bound to a freshly spawned terminal emulator
    # window (see `Window.open`). `window` is the window now bound to a terminal.
    event WindowOpened, window : Crysterm::Window

    # Emitted when the terminal emulator window backing a `Window` goes away —
    # typically because the user closed it. The `Window` is only disconnected
    # (not destroyed); re-attach via `Window.open(into: screen)` or tear it down
    # with `screen.destroy`. `window` is the affected window.
    event WindowClosed, window : Crysterm::Window

    # Emitted by an `Application` when a new physical device (`Screen`) is added —
    # i.e. the first window on a tty is registered ↔ `QGuiApplication::screenAdded`.
    # `screen` is the device.
    event ScreenAdded, screen : Crysterm::Screen

    # Emitted by an `Application` when a device (`Screen`) is no longer backing any
    # of its windows ↔ `QGuiApplication::screenRemoved`. `screen` is the device.
    event ScreenRemoved, screen : Crysterm::Screen

    # Emitted when widget focuses. Requires terminal supporting the focus protocol.
    event Focus, el : Widget? = nil

    # Emitted when widget goes out of focus. Requires terminal supporting the focus protocol.
    event Blur, el : Widget? = nil

    # Emitted when a widget's scroll position changes. `delta` is the signed
    # change in lines (positive = toward content end; `0` if reasserted without
    # moving); `orientation` is the axis (`:vertical` only for now). Both default
    # so `emit Event::Scroll` still works without computing a delta.
    event Scroll, delta : Int32 = 0, orientation : Tput::Orientation = :vertical

    # # Emitted on some data
    # event Data, data : String

    # # Emitted on a warning event
    # event Warning, message : String

    # Emitted when screen is resized.
    event Resize, size : Tput::Namespace::Size? = nil

    # Emitted when the user pastes text and bracketed paste (DEC 2004) is
    # enabled (`Window#enable_bracketed_paste`). `content` is the pasted text
    # verbatim, never interpreted as key presses. A programmatic clipboard
    # *read* reply arrives as `Clipboard` (below), not as a paste.
    event Paste, content : String

    # Emitted when an OSC 52 clipboard *read* reply arrives, in answer to a
    # `Window#request_clipboard` / `Application::Clipboard#request` — the
    # `QClipboard::dataChanged` analogue. `content` is the decoded clipboard text.
    # Distinct from `Paste`: this is the clipboard reported back asynchronously,
    # not the user pasting. `Application#clipboard` is refreshed from it first.
    event Clipboard, content : String

    # Emitted when the terminal reports a light/dark color-scheme change, once
    # `Window#enable_color_scheme_notifications` (DEC 2031) is active.
    event ColorScheme, scheme : ::Tput::ColorScheme

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

    # Emitted by an `Action` when a display-affecting property (`text`,
    # `enabled`, `checkable`, `checked`, `visible`) changes, so any widget
    # presenting the action can refresh. Mirrors Qt's `QAction::changed()`.
    event Changed

    # A granular change to a `Reactive::ObservableList`. `op` says what happened
    # (`Reactive::ListOp`); `index`/`count` locate it (`0` for `Reset`). Consumed
    # by `Reactive.bind_items` to patch a bound item view row-by-row.
    event ListChanged, op : ::Crysterm::Reactive::ListOp, index : Int32 = 0, count : Int32 = 0

    # Emitted on checkbox checked
    event Check, value : Bool

    # Emitted on checkbox unchecked
    event UnCheck, value : Bool

    # Emitted when a tri-state checkbox enters its partially-checked
    # (indeterminate) state. Mirrors Qt's `Qt::PartiallyChecked`.
    event PartialCheck, value : Bool

    # Emitted on every keystroke as an editable text widget's (e.g.
    # `Widget::LineEdit`) text changes, not just on submit. Mirrors Qt's
    # `QLineEdit#textChanged(QString)`.
    event TextChanged, value : String

    # Emitted by a `TextDocument` after every edit: `chars_removed` then
    # `chars_added` characters at `position`. Format-only changes report
    # `chars_removed == chars_added` over the affected range. Mirrors Qt's
    # `QTextDocument#contentsChange(int, int, int)`; `kind` additionally says
    # how positions were affected (see `TextDocument::ChangeKind`), which
    # views need to keep their own `Int32` carets adjusted like registered
    # `TextCursor`s.
    event ContentsChanged, position : Int32, chars_removed : Int32, chars_added : Int32, kind : Crysterm::TextDocument::ChangeKind = :edit

    # Emitted by a `TextDocument` when its number of blocks (paragraphs)
    # changes. Mirrors Qt's `QTextDocument#blockCountChanged(int)`.
    event BlockCountChanged, count : Int32

    # Emitted by a `TextDocument` when its modified state flips (edits away
    # from / undo back to the last clean point; see `TextDocument#modified=`).
    # Mirrors Qt's `QTextDocument#modificationChanged(bool)`.
    event ModificationChanged, modified : Bool

    # Emitted by a `TextDocument` when undo becomes possible/impossible.
    # Mirrors Qt's `QTextDocument#undoAvailable(bool)`.
    event UndoAvailable, available : Bool

    # Emitted by a `TextDocument` when redo becomes possible/impossible.
    # Mirrors Qt's `QTextDocument#redoAvailable(bool)`.
    event RedoAvailable, available : Bool

    # Emitted when a numeric widget's value changes (e.g. `Widget::ProgressBar`).
    # Mirrors Qt's `valueChanged(int)` signal.
    event ValueChanged, value : Int32

    # Emitted when a ranged widget's `[minimum, maximum]` bounds change (e.g.
    # `Widget::ScrollBar` resyncing to a scrollable target's content size).
    # Mirrors Qt's `QAbstractSlider#rangeChanged(int, int)` signal.
    event RangeChanged, minimum : Int32, maximum : Int32

    # Emitted when a floating-point numeric widget's value changes (e.g.
    # `Widget::DoubleSpinBox`). Mirrors Qt's `valueChanged(double)` signal.
    event DoubleValueChanged, value : Float64

    # Emitted by `Widget::Graph::HeatMap` when the pointer hovers a different
    # grid cell, carrying that cell's zero-based `row`/`col` and its `value`.
    # Fires only on a cell change, not on every motion report.
    event CellHover, row : Int32, col : Int32, value : Float64

    # Emitted when a date/time widget's value changes (e.g. `Widget::Calendar`,
    # `Widget::DateEdit`, `Widget::TimeEdit`). Mirrors Qt's
    # `dateChanged`/`timeChanged` signals.
    event DateChanged, date : Time

    # Emitted when a `Widget::Calendar`'s displayed month/year page changes
    # (without necessarily changing the selected date). Mirrors Qt's
    # `QCalendarWidget#currentPageChanged(year, month)` signal.
    event CurrentPageChanged, year : Int32, month : Int32

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

    # Emitted when a document link/anchor is activated — the analog of Qt's
    # `QTextBrowser::anchorClicked`. Carries the link's URL. Used by
    # `Widget::Markdown#activate_link` and `Widget::TextBrowser`.
    event AnchorClick, url : String

    # Emitted when `Widget::TextBrowser` navigates to a new source (the
    # analog of Qt's `QTextBrowser::sourceChanged`).
    event SourceChanged, url : String

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

    # Emitted by `Widget::Tree` when a node is expanded or collapsed. `index` is
    # the node's visible row at the time of the change. Mirror Qt's
    # `QTreeView#expanded`/`#collapsed` signals.
    event Expand, index : Int32
    # :ditto:
    event Collapse, index : Int32

    # Emitted on selection of an item in list
    event SelectItem, item : Widget::Box, index : Int32

    # Emitted by `Widget::ListBar` when a tab/command is selected via
    # `#select_tab` (e.g. through `auto_command_keys`). `item` is the command's
    # element box (`nil` if the index is out of range), `index` its position.
    event SelectTab, item : Widget::Box?, index : Int32

    # Emitted when an `Action` is triggered (Qt's `QAction::triggered(bool)`).
    # `checked` carries the action's checked state *after* activation, so a
    # checkable action reports its new on/off value to the handler; it is always
    # `false` for non-checkable actions.
    event Triggered, checked : Bool = false

    # Emitted when a Widget or Action are hovered
    event Hovered

    # Emitted when an `Action`'s checked state changes — programmatically or via
    # activation (Qt's `QAction::toggled(bool)`). `checked` is the new state.
    # Distinct from `Triggered`: `Toggled` fires on *any* checked change, whereas
    # `Triggered` fires only on activation.
    event Toggled, checked : Bool

    # Emitted when an `Action`'s `enabled` changes (Qt's
    # `QAction::enabledChanged(bool)`). Granular complement to `Changed`.
    event EnabledChanged, enabled : Bool

    # Emitted when an `Action`'s `checkable` changes (Qt's
    # `QAction::checkableChanged(bool)`). Granular complement to `Changed`.
    event CheckableChanged, checkable : Bool

    # Emitted when an `Action`'s `visible` changes (Qt's
    # `QAction::visibleChanged(bool)`). Granular complement to `Changed`.
    event VisibleChanged, visible : Bool

    # Emitted when a closable panel (e.g. `Widget::DockWidget`) is closed via its
    # own UI (the title-bar `✕`). Mirrors Qt's close-event/`visibilityChanged`.
    event Close

    # Emitted when a `Widget::DockWidget` is floated or re-docked. `value` is
    # whether it is now floating (Qt's `QDockWidget#topLevelChanged`).
    event Float, value : Bool

    # Emitted by a dialog (e.g. `Widget::DialogButtonBox`, `Widget::ColorDialog`)
    # when the user activates an accepting control (Ok/Yes/Save/…). Mirrors Qt's
    # `QDialogButtonBox#accepted`/`QDialog#accepted`.
    event Accepted

    # Emitted by a dialog when the user activates a rejecting control
    # (Cancel/No/Close/…) or dismisses it. Mirrors Qt's
    # `QDialogButtonBox#rejected`/`QDialog#rejected`.
    event Rejected

    # Emitted by a `ButtonGroup` when one of its member buttons is activated.
    # `button` is the button that was clicked/toggled (Qt's
    # `QButtonGroup#buttonClicked`).
    event ButtonClick, button : Widget

    # Emitted by a dialog when it is done, whatever the outcome — after
    # `Accepted`/`Rejected`. `result` is the dialog's `Widget::Dialog#result`
    # (Qt's `QDialog#finished(int)`).
    event Finished, result : Int32

    # Emitted when a multi-page container's current page changes. `index` is the
    # new current index, or `-1` when there is no current page. Mirrors Qt's
    # `QTabWidget`/`QStackedWidget`/`QToolBox#currentChanged(int)`.
    event CurrentChanged, index : Int32

    # Emitted by an `Application` immediately before it quits, giving handlers a
    # last chance to save state. Mirrors Qt's `QCoreApplication#aboutToQuit`.
    event AboutToQuit

    # Emitted by a popup (e.g. `Widget::Menu`) just before it is shown, so a
    # handler can populate or update it first. Mirrors Qt's `QMenu#aboutToShow`.
    event AboutToShow

    # Emitted by a popup (e.g. `Widget::Menu`) just before it is hidden.
    # Mirrors Qt's `QMenu#aboutToHide`.
    event AboutToHide

    # Shared "accept/ignore" propagation-control behavior for events that can be
    # accepted to stop them from propagating further (`Key`, `Mouse`, `DragEvent`).
    module Acceptable
      property? accepted : Bool = false

      # Accepts event and causes it to stop propagating.
      def accept
        @accepted = true
      end

      # Ignores event and causes it to continue propagating.
      def ignore
        @accepted = false
      end
    end

    # Base class for keyboard events. Carries the key identity (`char` / `key` /
    # `sequence`) and, when the terminal speaks an enhanced keyboard protocol
    # (kitty / modifyOtherKeys) enabled via `Window#enable_keyboard_protocol`,
    # the rich `key_event` plus flat accessors for its details (`#alt?`,
    # `#modifier_key`, …) — all `nil`/`false` for legacy (un-enhanced) input,
    # none of which the flat `#key`/`#char` can express.
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

      # Raw input sequence backing `#sequence`. Stored nilable and materialized
      # lazily: plain typing carries `nil` here (the parser passes no array via
      # `Tput::InputEvent#sequence?`), so an ordinary keypress allocates no
      # `[@char]` array unless a consumer actually reads `#sequence`.
      @sequence : Array(Char)?

      # The rich keyboard event when an enhanced protocol is active, else `nil`.
      getter key_event : ::Tput::KeyEvent?

      def initialize(@char, @key = nil, @sequence : Array(Char)? = nil, @key_event = nil)
      end

      # Raw input sequence for this key. Lazily materializes the one-element
      # `[@char]` fallback on first read (and caches it), so plain typing stays
      # allocation-free until something asks for the sequence.
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
        # Whether the {{m.id}} modifier was held.
        def {{m.id}}? : Bool
          !!@key_event.try(&.{{m.id}}?)
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

    # A key release. Only emitted when an enhanced keyboard protocol with event
    # reporting is active (`Window#enable_keyboard_protocol(events: true)`);
    # otherwise the terminal never reports releases and this never fires.
    class KeyRelease < Key
    end

    # Emitted on any mouse activity (button press/release, motion, wheel).
    #
    # This is the single, normalized mouse event for Crysterm. It is emitted
    # both for mouse reports parsed from the terminal (xterm SGR/X10, via
    # `Tput`) and for events coming from the Linux console `gpm` daemon — both
    # sources are converted to a common `::Tput::Mouse::Event` and dispatched
    # through `Window#dispatch_mouse`, so listeners need not care about origin.
    #
    # It is emitted on the `Window` and, when the pointer is over a registered
    # clickable `Widget`, on that widget as well (see `Window#widget_at`).
    class Mouse < EventHandler::Event
      include Acceptable

      # The underlying normalized mouse event.
      property mouse : ::Tput::Mouse::Event

      def initialize(@mouse)
      end

      # Re-targets this (pooled) event at a new underlying `mouse` report and
      # clears any prior `accept`. Lets a `Window` reuse one `Mouse` (and one
      # each of its `MouseOver`/`MouseMove`/`MouseOut` subclasses) across
      # dispatches instead of allocating a fresh event per report while a
      # listener is installed. Caveat: a handler that *retains* the event will
      # see its fields mutate on the next report — handlers must copy anything
      # they need to keep past their own invocation.
      def reset(@mouse : ::Tput::Mouse::Event) : self
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
      # active (`Window#enable_mouse(pixels: true)`); `nil` otherwise. `x`/`y`
      # still carry the cell coordinates, so pixel-aware widgets (Canvas/Painter,
      # image widgets, precise drag) can read `px`/`py` without disturbing the
      # rest of the toolkit.
      def px : Int32?
        @mouse.px
      end

      # 0-based sub-cell pixel row; see `#px`.
      def py : Int32?
        @mouse.py
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

    # Hover events. These carry the same payload as `Mouse` (they subclass it)
    # but signal pointer *hovering* transitions rather than raw activity.
    #
    # They are emitted on a `Widget` only — and only on the **topmost** widget
    # under the pointer, mirroring how a click is dispatched (see
    # `Window#dispatch_mouse`). A widget that is occluded by another does not
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
      include Acceptable

      getter session : ::Crysterm::DragSession

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

      # Withdraws acceptance — the documented inverse of `#accept`. Must mirror
      # `#accept` and also clear the *session's* accepted flag, because
      # `drag_release`/`drop_external` decide whether to deliver `Drop` from
      # `session.data.accepted?`, not the event flag. Overriding
      # `Acceptable#ignore` (which only clears the event flag) so a target that
      # accepts then withdraws via `e.ignore` actually cancels the drop.
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
