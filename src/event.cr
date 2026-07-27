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

    # Emitted when widget is attached to a screen directly or somewhere in its ancestry
    event Attached, object : EventHandler

    # Emitted when widget is detached from a screen directly or somewhere in its ancestry
    event Detached, object : EventHandler

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
    # `previous` is the widget that previously held focus (`nil` if none).
    event FocusIn, previous : Widget? = nil

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

    # Emitted when screen is resized.
    event Resize, size : Tput::Namespace::Size? = nil

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

    # Emitted after Widget's content is defined
    event ContentChanged

    # Emitted after Widget's content is parsed
    event ContentParsed

    # Emitted on mouse click
    event Click

    # Emitted on button press
    event Pressed

    # Emitted by an `Action` when a display-affecting property (`text`,
    # `enabled`, `checkable`, `checked`, `visible`) changes, so any widget
    # presenting the action can refresh. Mirrors Qt's `QAction::changed()`.
    event Changed

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
    # `SliderMoved` never also emits it (A4-62).
    event SliderMoved, position : Int32

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
    event Completed

    # Emitted on something being reset (e.g. a `Widget::Form` being reset to
    # its initial state, or a progressbar reset to 0%).
    event Reset

    # Emitted on value submitted (e.g. in text forms)
    event Submitted, value : String

    # Emitted when a `Widget::Form` is submitted. Carries the collected
    # name => value pairs of all input children.
    event FormSubmitted, data : Widget::Form::FormData

    # Emitted when a document link/anchor is activated, carrying the link's URL.
    # The analog of Qt's `QTextBrowser::anchorClicked`.
    event AnchorClick, url : String

    # Emitted when `Widget::TextBrowser` navigates to a new source (the
    # analog of Qt's `QTextBrowser::sourceChanged`).
    event SourceChanged, url : String

    # Emitted on value canceled (e.g. in text forms). `value` is the current
    # value when one applies (text editors), `nil` for a bare dismissal.
    event Cancelled, value : String? = nil

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

    event ItemCancelled, item : Widget::Box, index : Int32
    event ItemActivated, item : Widget::Box, index : Int32

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

    # Emitted on selection of an item in list
    event ItemSelected, item : Widget::Box, index : Int32

    # Emitted when an `Action` is triggered (Qt's `QAction::triggered(bool)`).
    # `checked` is the action's state *after* activation; always `false` for a
    # non-checkable action.
    event Triggered, checked : Bool = false

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

    # Emitted by a `Window` during a drag with a human-readable status update
    # ("Picked up …", "Over …", "Dropped on …", "Cancelled"), for a status-line
    # "live region" — the accessibility counterpart to the drag's on-screen
    # feedback. `text` is the message. A no-op sink is nothing to subscribe.
    event DragAnnounced, text : String
  end
end
