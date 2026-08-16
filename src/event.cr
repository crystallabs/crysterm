require "event_handler"
require "tput"

module Crysterm
  # The check state of a tri-state checkable (Qt's `Qt::CheckState`). Carried by
  # `Event::StateChanged`.
  enum CheckState
    Unchecked
    PartiallyChecked
    Checked
  end

  # Typed result of a `Widget::Form#submit`: the collected fields in subtree
  # order, with `Hash`-like access by field name. Several inputs may share one
  # name (a radio/checkbox group); `#[]` returns the first such field's value
  # and `#values_for` all of them.
  #
  # Declared here — beside the `Event::FormSubmitted` event that carries it —
  # rather than inside `Widget::Form`, so the core event catalog references no
  # concrete widget type. `Widget::Form::FormData`/`Widget::Form::
  # FieldValue` alias these for the conventional form-side spelling.
  class FormData
    # The natively-typed value of one submitted field: text widgets and item
    # views contribute a `String`, check/radio buttons a `Bool`, `SpinBox`
    # an `Int32`, `DoubleSpinBox` a `Float64`, and the date/time editors a
    # `Time`.
    alias FieldValue = String | Bool | Int32 | Float64 | Time

    # One collected input: the contributing widget, its resolved name
    # (the widget's `#name`, falling back to its type name) and its
    # `FieldValue`.
    record Field, widget : Widget, name : String, value : FieldValue

    include Enumerable(Field)

    # The collected fields, in subtree (submission) order.
    getter fields = [] of Field

    def each(& : Field ->)
      @fields.each { |f| yield f }
    end

    protected def add(widget : Widget, name : String, value : FieldValue) : Nil
      @fields << Field.new(widget, name, value)
    end

    # Value of the first field named *name*; raises `KeyError` when absent.
    def [](name : String) : FieldValue
      self[name]? || raise KeyError.new "Missing form field: #{name.inspect}"
    end

    # Value of the first field named *name*, or `nil`.
    def []?(name : String) : FieldValue?
      @fields.find(&.name.==(name)).try &.value
    end

    # Values of every field named *name*, in subtree order — a radio or
    # checkbox group sharing one name arrives here as one `Bool` each.
    def values_for(name : String) : Array(FieldValue)
      @fields.select(&.name.==(name)).map &.value
    end

    def has_key?(name : String) : Bool
      @fields.any? &.name.==(name)
    end

    # The distinct field names, in first-appearance order.
    def names : Array(String)
      seen = Set(String).new
      @fields.compact_map { |f| f.name if seen.add?(f.name) }
    end

    def empty? : Bool
      @fields.empty?
    end

    def size : Int32
      @fields.size
    end

    # First-field-wins `name => value` view (matching `#[]`); duplicate
    # names lose their later values — use `#values_for` for those.
    def to_h : Hash(String, FieldValue)
      h = {} of String => FieldValue
      @fields.each { |f| h[f.name] = f.value unless h.has_key? f.name }
      h
    end
  end

  # Collection of all events used by Crysterm.
  #
  # ## Naming
  #
  # An event's name states the stage of the action it reports:
  #
  # * **`Pre`- / `AboutTo`-prefixed** — emitted *before* the action, so a handler
  #   can still act on the old state (`PreRender`, `AboutToQuit`). Use `AboutTo`
  #   where Qt has a signal of that exact name (`aboutToQuit`, `aboutToShow`,
  #   `aboutToHide`); `Pre` otherwise.
  # * **Noun** — a discrete occurrence, emitted as it happens (`Click`, `Move`,
  #   `Resize`, `Paste`); the analogue of Qt's event classes.
  # * **Past tense** — state has *already* changed (`Rendered`, `ValueChanged`,
  #   `TextChanged`, `Toggled`), carrying the new value where one applies.
  #
  # A property-change event must therefore be past tense, emitted *after* the
  # assignment, and guarded so it fires only on an actual change.
  #
  # ## Choosing an activation event
  #
  # Four events report "something was activated"; they differ by emitter and by
  # what counts as activation:
  #
  # * `Click` — raw mouse only, emitted by the `Window`'s mouse routing on the
  #   widget under a completed press+release. No keyboard equivalent. Subscribe
  #   for pointer-specific behavior (a clickable region, a hit-test target).
  # * `Clicked` — a button's *full activation*, mouse **or** keyboard
  #   (Space/Enter), emitted by `Widget::AbstractButton` (Qt's `clicked()`).
  #   This is what a push button's "was it pressed?" handler wants.
  # * `Triggered` — emitted by an `Action` (never by a widget) when it is
  #   activated through any of its surfaces: a menu entry, a tool button, or its
  #   keyboard accelerator. Carries the action's post-activation `checked` state.
  #   Subscribe on the `Action`, not on the widgets presenting it.
  # * `Activated` — a widget committed a *chosen value*, carried as `value`
  #   (a `Widget::ComboBox` entry, a `Widget::ColorDialog` hex, a Pine key
  #   prompt's key). Subscribe when the payload — not the gesture — is the point.
  #
  # Events currently unused have been commented. Uncomment on first use.
  module Event
    include EventHandler

    # Shared "accept/ignore" propagation-control behavior for events that can be
    # accepted to stop them from propagating further (`Key`, `Mouse`,
    # `DragEvent`, `Paste`). Defined before the first including class: `include`
    # resolves in file order.
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

    # Emitted when widget is attached to a screen directly or somewhere in its
    # ancestry. `window` is the window just joined.
    event Attached, window : Crysterm::Window

    # Emitted when widget is detached from a screen directly or somewhere in its
    # ancestry. `window` is the window just left — by the time this fires the
    # widget's own `#window?`/`#parent` are already nulled, so teardown that
    # needs the departing window must read it here.
    event Detached, window : Crysterm::Window

    # Emitted when widget gains a new parent
    event Reparented, widget : Widget?

    # Emitted when widget is added to parent
    event ChildAdded, widget : Widget

    # Emitted when widget is removed from its current parent
    event ChildRemoved, widget : Widget

    # Emitted when Widget is destroyed
    event Destroy

    # Emitted when a child process backing a widget (e.g. `Widget::Terminal`'s
    # shell) exits. `code` is the process exit status, or `nil` if unknown.
    event ProcessExited, code : Int32? = nil

    # Emitted when a `Window` is bound to a freshly spawned terminal emulator
    # window. `window` is the window now bound to a terminal.
    event WindowOpened, window : Crysterm::Window

    # Emitted when the terminal emulator window backing a `Window` goes away —
    # typically because the user closed it. The `Window` is only disconnected
    # (not destroyed); re-attach via `Window.open(into: window)` or tear it down
    # with `window.destroy`. `window` is the affected window.
    event WindowClosed, window : Crysterm::Window

    # Emitted by an `Application` when a new physical device (`Screen`) is added —
    # i.e. the first window on a tty is registered ↔ `QGuiApplication::screenAdded`.
    # `screen` is the device.
    event ScreenAdded, screen : Crysterm::Screen

    # Emitted by an `Application` when a device (`Screen`) is no longer backing any
    # of its windows ↔ `QGuiApplication::screenRemoved`. `screen` is the device.
    event ScreenRemoved, screen : Crysterm::Screen

    # Emitted when widget focuses. Requires terminal supporting the focus protocol.
    # `previous_focused` is the widget that previously held focus (`nil` if none).
    event FocusIn, previous_focused : Widget? = nil

    # Emitted when widget goes out of focus. Requires terminal supporting the focus protocol.
    # `next_focused` is the widget taking focus (`nil` if focus is being cleared).
    event FocusOut, next_focused : Widget? = nil

    # Emitted when a widget's scroll position changes. `delta` is the signed
    # change in lines (positive = toward content end; `0` if reasserted without
    # moving); `orientation` is the axis (`:vertical` only for now). Both default
    # so `emit Event::Scroll` still works without computing a delta.
    event Scroll, delta : Int32 = 0, orientation : Tput::Orientation = :vertical

    # # Emitted on some data
    # event Data, data : String

    # # Emitted on a warning event
    # event Warning, message : String

    # Emitted when the emitter's size changed: by a `Widget` whose geometry or
    # size constraints were reassigned, by a `Window` after its device resized
    # (then fanned out to every descendant), and on `GlobalEvents` by the
    # SIGWINCH trap as the process-wide "a terminal changed size" signal.
    #
    # Parameterless: a widget-level emit happens at assignment time, before any
    # layout pass has resolved the new geometry, so there is no size to carry
    # yet. The terminal's new size rides on `DeviceResize`.
    event Resize

    # Emitted on a `Window` when its device (terminal) reported a new size.
    # `size` is that size — Crysterm's own `Size` record (the single geometry
    # vocabulary), not tput's mutable class — and is always present. The window
    # resizes its `Screen` from it and then emits the parameterless `Resize`
    # on itself and every descendant.
    event DeviceResize, size : Crysterm::Size

    # Emitted when the user pastes text and bracketed paste (DEC 2004) is
    # enabled (`Window#enable_bracketed_paste`). `content` is the pasted text
    # verbatim, never interpreted as key presses. A programmatic clipboard
    # *read* reply arrives as `ClipboardChanged` (below), not as a paste.
    #
    # Routed like a key press: offered to the focused widget and up its parent
    # chain until a handler `#accept`s it (text-editing widgets insert it at
    # the cursor, `Widget::Terminal` forwards it to the child), then emitted on
    # the `Window` as the unaccepted fallback. Defined as a class (not via the
    # `event` macro) to include `Acceptable`.
    class Paste < EventHandler::Event
      include Acceptable

      getter content : String

      def initialize(@content)
      end
    end

    # Emitted when an OSC 52 clipboard *read* reply arrives, in answer to a
    # `Window#request_clipboard` / `Application::Clipboard#request` — the
    # `QClipboard::dataChanged` analogue. `content` is the decoded clipboard text.
    # Distinct from `Paste`: this is the clipboard reported back asynchronously,
    # not the user pasting. `Application#clipboard` is refreshed from it first.
    event ClipboardChanged, content : String

    # Emitted when the terminal reports a light/dark color-scheme change, once
    # `Window#enable_color_scheme_notifications` (DEC 2031) is active.
    event ColorSchemeChanged, scheme : ::Tput::ColorScheme

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

    # Emitted after a `Widget`'s own content string is (re)set — by
    # `#content=`/`#set_content` and by the incremental append path. Carries no
    # payload; read `#content` off the sender. Distinct from the document-side
    # `ContentsChanged`, which reports an edit *range* inside a `TextDocument`.
    event ContentSet

    # Emitted after Widget's content is parsed
    event ContentParsed

    # Emitted on mouse click
    event Click

    # Emitted on a button's full activation — mouse click OR keyboard
    # (Space/Enter) — matching Qt's `clicked()`, NOT its press-only
    # `pressed()`. Named `Clicked` for exactly that reason; the raw mouse
    # button-down is `Event::Click` above.
    event Clicked

    # Historical name for `Clicked`, kept as a compatible spelling: it fires on
    # full activation (Qt's `clicked()`), not on button-down, which the old
    # name wrongly suggested.
    alias Pressed = Clicked

    # Emitted by an `Action` when a display-affecting property (`text`,
    # `enabled`, `checkable`, `checked`, `visible`) changes, so any widget
    # presenting the action can refresh. Mirrors Qt's `QAction::changed()`.
    event Changed

    # Emitted by a `Reactive::Property`/`Reactive::Computed` when its value
    # changed — the reactive layer's own notification, kept distinct from
    # `Changed` so an object that is both an action host and a reactive owner
    # can tell the two apart. Carries no payload: read `#value` off the sender.
    event ReactiveChanged

    # A granular change to a `Reactive::ObservableList`. `op` says what happened;
    # `index`/`count` locate it (`0` for `Reset`).
    event ListChanged, op : ::Crysterm::Reactive::ListOp, index : Int32 = 0, count : Int32 = 0

    # Emitted when a checkable widget's check state changes, carrying the new
    # `state` (`Unchecked`/`PartiallyChecked`/`Checked`). Mirrors Qt's
    # `QCheckBox#stateChanged(int)`. For the plain Bool view use `Toggled`.
    event StateChanged, state : CheckState

    # Emitted on every keystroke as an editable text widget's (e.g.
    # `Widget::LineEdit`) text changes, not just on submit. Mirrors Qt's
    # `QLineEdit#textChanged(QString)`.
    event TextChanged, value : String

    # Emitted alongside `TextChanged` when the change came from the *user*
    # (typing, paste, kill/yank, table-cell editing) rather than a
    # programmatic `value=`/`set_*` — Qt's `QLineEdit#textEdited(QString)`
    # distinction. `value` is the new text, as in `TextChanged`.
    event TextEdited, value : String

    # Emitted by an editable text widget when its insertion point moved —
    # Qt's `cursorPositionChanged()`, with the new position attached:
    # `position` is the caret's codepoint index into the buffer
    # (`Mixin::TextEditing#cursor_position`). The "Ln 4, Col 12" status-bar
    # hook; map the flat position to line/column via the widget's own
    # geometry, or a document cursor for the document-backed editors.
    event CursorPositionChanged, position : Int32

    # Emitted by an editable text widget when its selection changed —
    # extended, moved, or dropped (Qt's `selectionChanged()`). Parameterless,
    # as in Qt: read `#selected_text`/`#selection_range` off the sender (the
    # payload is not precomputed — building the selected string per mouse-drag
    # step would be wasted work with no listener).
    event SelectionChanged

    # Emitted by a `TextDocument` after every edit: `chars_removed` then
    # `chars_added` characters at `position`. Format-only changes report
    # `chars_removed == chars_added` over the affected range. Mirrors Qt's
    # `QTextDocument#contentsChange(int, int, int)`, plus `kind`, which says how
    # positions moved — a view holding its own `Int32` carets must adjust them by
    # it, as registered `TextCursor`s are adjusted automatically. Also stands in
    # for Qt's parameterless `contentsChanged()` — both of Qt's post-edit
    # signals collapse onto this one unified event.
    event ContentsChanged, position : Int32, chars_removed : Int32, chars_added : Int32, kind : Crysterm::TextDocument::ChangeKind = :edit

    # Emitted by a `TextDocument` when its number of blocks (paragraphs)
    # changes. Mirrors Qt's `QTextDocument#blockCountChanged(int)`.
    event BlockCountChanged, count : Int32

    # Emitted by a `TextDocument` when its modified state flips (edits away
    # from / undo back to the last clean point).
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

    # Emitted on every drag motion of a `Widget::Slider`/`Widget::ScrollBar`
    # handle, carrying the candidate position (already clamped into
    # `[minimum, maximum]`) — Qt's `QAbstractSlider#sliderMoved(int)`. Fires
    # on every move regardless of `#tracking?` (Qt fires it unconditionally);
    # `Event::ValueChanged` already covers the tracking-on per-move case, and
    # `SliderMoved` never also emits it.
    event SliderMoved, position : Int32

    # Emitted when a floating-point numeric widget's value changes (e.g.
    # `Widget::DoubleSpinBox`). Mirrors Qt's `valueChanged(double)` signal.
    event DoubleValueChanged, value : Float64

    # Emitted when a floating-point ranged widget's `[minimum, maximum]` bounds
    # change (e.g. `Widget::DoubleSpinBox`) — the `Float64` counterpart of
    # `Event::RangeChanged`, paired with `Event::DoubleValueChanged`.
    #
    # The payload is a concrete type per event class (the `event` macro
    # generates one class per signal), so the numeric signals come in `Int32` /
    # `Float64` pairs rather than as one generic event; `Mixin::RangedValue`
    # routes each instantiation to its own pair.
    event DoubleRangeChanged, minimum : Float64, maximum : Float64

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
    event Completed

    # Emitted on something being reset (e.g. a `Widget::Form` being reset to
    # its initial state, or a progressbar reset to 0%).
    event Reset

    # Emitted on value submitted (e.g. in text forms)
    event Submitted, value : String

    # Emitted when a `Widget::Form` is submitted. Carries the collected
    # name => value pairs of all input children (a `Crysterm::FormData`,
    # conventionally spelled `Widget::Form::FormData`).
    event FormSubmitted, data : Crysterm::FormData

    # Emitted when a document link/anchor is activated, carrying the link's URL.
    # The analog of Qt's `QTextBrowser::anchorClicked`.
    event AnchorClick, url : String

    # Emitted when `Widget::TextBrowser` navigates to a new source (the
    # analog of Qt's `QTextBrowser::sourceChanged`).
    event SourceChanged, url : String

    # Emitted on value canceled (e.g. in text forms). `value` is the current
    # value when one applies (text editors), `nil` for a bare dismissal.
    event Cancelled, value : String? = nil

    # Emitted when editing of a persistent form field finishes — Qt's
    # `editingFinished`. Fires once per completed edit session,
    # whichever way the session ends; `Submitted`/`Cancelled` keep their
    # narrower meanings (explicit submit / explicit-or-implicit dismissal)
    # and distinguish the *outcome*, while this marks the session boundary
    # itself. The firing contract per emitter:
    #
    # * `Widget::LineEdit` (the `Mixin::TextEditing` read session): emitted
    #   exactly once when the read session ends — Enter (submit), focus-out,
    #   or Escape (which ends the whole session in this model, unlike Qt's
    #   revert-in-place). When Enter both submits and ends the session,
    #   `Submitted` and `EditingFinished` each fire once, in one teardown —
    #   never doubled.
    # * The spin boxes (`Mixin::SpinBoxEditing`): emitted when Enter commits a
    #   typed entry, and on every focus-out (Qt's `QAbstractSpinBox` fires
    #   there unconditionally — stepping counts as editing too). A silent
    #   in-place buffer discard (Escape, or a step/wheel abandoning a
    #   half-typed entry) is not a finish: the user is still in the field.
    #
    # Parameterless, as in Qt: listeners read the sender's `#value`/`#text`.
    event EditingFinished

    # Emitted by `Widget::FileManager` when the current directory changes.
    # `path` is the directory just entered; `previous` is the directory left behind.
    event DirectoryChanged, path : String, previous : String

    # Emitted by `Widget::FileManager` when a (non-directory) file is selected.
    event FileSelected, path : String

    # Emitted by `Widget::FileManager` after its listing is (re)loaded, and by
    # any widget that reloads its contents from an external source.
    event Refresh

    # Emitted when a widget is activated carrying a chosen string value (e.g.
    # `Widget::ComboBox` text, `Widget::ColorDialog` hex, a Pine key prompt's
    # key). `value` is that chosen string.
    event Activated, value : String

    # Emitted by `Widget::Calendar` when a day is activated (Enter or click),
    # carrying the activated `date`. The past-tense counterpart to `DateChanged`.
    event DateActivated, date : Time

    # Emitted on addition of a list item to list
    event ItemAdded
    # Emitted on insertion of a list item at a given position
    event ItemInserted
    # Emitted on removal of a list item
    event ItemRemoved
    # Emitted on re-set/re-definition of list items
    event ItemsChanged

    # `item` is typed as the `Widget` base — emitters pass their item boxes
    # (`Mixin::ItemView`/`Mixin::ActionBar` rows, a `ToolBox` header), but the
    # core catalog must not reference concrete widget types, and
    # handlers only need the identity/index.
    event ItemCancelled, item : Widget, index : Int32
    # :ditto:
    event ItemActivated, item : Widget, index : Int32

    # Event emitted when a new log line intended for `Widget::Log` is issued
    event Log, text : String
    # NOTE Blessed's counterpart is `log`; the name must not collide with the
    # logger's own `Log`.

    # Emitted by `Widget::Tree` when a node is expanded or collapsed. `index` is
    # the node's visible row at the time of the change. Mirror Qt's
    # `QTreeView#expanded`/`#collapsed` signals.
    event Expanded, index : Int32
    # :ditto:
    event Collapsed, index : Int32

    # Emitted by the chat composer (`Widget::Chat::ChatBox`) when the
    # permission mode changes — the typed complement to the status line's
    # `CurrentChanged`, which carries only the mode's raw enum value.
    # `Chat::Mode` is a model type (like `FormData` above), not a widget type,
    # so the no-widget-types rule for this catalog is respected.
    event ModeChanged, mode : ::Crysterm::Chat::Mode

    # Emitted by the chat composer when a background task first reaches a
    # terminal state (ok/fail/cancelled) — the typed completion notification
    # layered over the registry's row-level `ListChanged` `Update`, which
    # fires on *any* field change.
    event TaskCompleted, task : ::Crysterm::Chat::Task

    # Emitted on selection of an item in list. `item` is the `Widget` base for
    # the same reason as `ItemActivated`.
    event ItemSelected, item : Widget, index : Int32

    # Emitted when an `Action` is triggered (Qt's `QAction::triggered(bool)`).
    # `checked` is the action's state *after* activation; always `false` for a
    # non-checkable action. `action` is the action that fired — preserved when an
    # `ActionGroup` relays the event, so a group-level subscriber knows which
    # member activated (Qt's `QActionGroup::triggered(QAction*)`).
    #
    # Both fields are mandatory: only `Action#activate` and `ActionGroup`'s relay
    # emit this, and both always know the state and the originating action.
    event Triggered, checked : Bool, action : Crysterm::Action

    # Emitted when a Widget or Action are hovered
    event Hovered

    # Emitted when an `Action`'s checked state changes — programmatically or via
    # activation (Qt's `QAction::toggled(bool)`). `checked` is the new state.
    # Unlike `Triggered`, this fires on *any* checked change, not just activation.
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

    # Emitted when a `Widget::DockWidget` is floated or re-docked. `floating` is
    # whether it is now floating (Qt's `QDockWidget#topLevelChanged`).
    event TopLevelChanged, floating : Bool

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

    # Emitted by a `Window` during a drag with a human-readable status update
    # ("Picked up …", "Over …", "Dropped on …", "Cancelled"), for a status-line
    # "live region" — the accessibility counterpart to the drag's on-screen
    # feedback. `text` is the message. A no-op sink is nothing to subscribe.
    event DragAnnounced, text : String
  end
end
