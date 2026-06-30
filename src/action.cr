require "event_handler"
require "tput"

module Crysterm
  # Many common commands can be invoked via different interfaces (menus, toolbar buttons, keyboard shortcuts, etc.).
  # Because they are expected to run in the same way, regardless of the user interface used, it is useful to represent them with `Action`s.
  #
  # Actions can be added to menus and toolbars, and will automatically be kept in sync because they are the same object.
  # For example, if the user presses a "Bold" toolbar button in a text editor, the "Bold" menu item will automatically appear enabled where ever it is added.
  #
  # It is recommended to create `Action`s as children of the window they are used in.
  #
  # Actions are added to `Widget`s using `#addAction` or `<<(Action)`. Note that an action must be added to a widget before it can be used.
  #
  # NOTE Actions are inspired by `QAction` (https://doc.qt.io/qt-6/qaction.html)
  class Action
    include EventHandler

    alias OneOfEvents = Crysterm::Event::Triggered.class | Crysterm::Event::Hovered.class

    # A single keystroke in a shortcut — a named `Tput::Key` (the enum already
    # encodes the `Ctrl*`/`Shift*`/`Alt*` chord members, e.g. `CtrlB`, `CtrlUp`).
    alias KeyStroke = ::Tput::Key

    # An ordered sequence of keystrokes forming one shortcut (Qt's `QKeySequence`),
    # e.g. `[Tput::Key::CtrlK, Tput::Key::CtrlB]` for the chord "Ctrl+K, Ctrl+B".
    # A plain single-key shortcut is a one-element sequence.
    alias KeySequence = Array(KeyStroke)

    # User payload carried on the action (Qt's `QAction::data`). A primitive
    # value — typically an id or command name — attached to the action and read
    # back in a `Triggered` handler. (Crystal disallows a universal `QVariant`
    # type; for a richer payload, carry an id here and look the object up, or
    # subclass `Action`.)
    alias Data = String | Int32 | Int64 | Float64 | Bool

    # Relative importance of the action (Qt's `QAction::Priority`). A toolbar may
    # consult it to decide whether to show an action's text beside its glyph.
    enum Priority
      Low
      Normal
      High
    end

    # When an action's `#shortcut` is active (Qt's `Qt::ShortcutContext`).
    # `Window` (the default) and `Application` fire regardless of focus while the
    # action is installed on a window; `Widget`/`WidgetWithChildren` fire only
    # when the action's host widget holds focus.
    enum ShortcutContext
      Widget
      WidgetWithChildren
      Window
      Application
    end

    # Defines a `name=` setter that assigns only on an actual change and then
    # calls `#notify_changed` (emitting `Event::Changed`), so observers (menus,
    # toolbars) refresh. Skipping the emit on a redundant assignment is what keeps
    # repeated/no-op assignments from triggering needless re-renders. Shared by
    # the display-affecting `Action` properties whose only side effect is a
    # refresh; the ones that ALSO emit a granular event (enabled/checkable/
    # checked/visible) define their setters explicitly below.
    private macro notifying_setter(name, type)
      def {{ name.id }}=(value : {{ type }}) : {{ type }}
        return value if @{{ name.id }} == value
        @{{ name.id }} = value
        notify_changed
        value
      end
    end

    # The action's icon (Qt's `QAction::icon`). A terminal has no pixmap, so this
    # is a Unicode glyph (or short string) such as `"📁"`, `"✂"`, `"▶"` — rendered
    # before the label by menus and tool buttons. Meaningful wherever the font
    # carries the glyph.
    getter icon : String?

    # :ditto:
    notifying_setter icon, String?

    # Short text shown alongside (or instead of) the icon on compact surfaces such
    # as a tool button (Qt's `QAction::iconText`).
    getter icon_text : String?

    # :ditto:
    notifying_setter icon_text, String?

    # Text / label of action
    getter text : String = ""

    # :ditto:
    notifying_setter text, String

    # Action enabled?
    getter enabled = true

    # Sets `#enabled`, emitting the granular `Event::EnabledChanged` (Qt's
    # `enabledChanged`) plus the umbrella `Event::Changed`, only on a real change.
    def enabled=(value : Bool) : Bool
      return value if @enabled == value
      @enabled = value
      emit ::Crysterm::Event::EnabledChanged, value
      notify_changed
      value
    end

    # Whether the action has an on/off checked state (Qt's `QAction#checkable`),
    # e.g. a toggleable "Word Wrap" menu entry. A `Widget::Menu` draws a
    # `[x]`/`[ ]` marker for checkable actions and flips `#checked?` when they are
    # activated.
    getter? checkable = false

    # Sets `#checkable`, emitting the granular `Event::CheckableChanged` (Qt's
    # `checkableChanged`) plus `Event::Changed`, only on a real change.
    def checkable=(value : Bool) : Bool
      return value if @checkable == value
      @checkable = value
      emit ::Crysterm::Event::CheckableChanged, value
      notify_changed
      value
    end

    # Current checked state; only meaningful when `#checkable?`.
    getter? checked = false

    # Sets `#checked`, emitting `Event::Toggled` (Qt's `toggled(bool)`) plus
    # `Event::Changed`, only on a real change. `Toggled` fires on *any* checked
    # change — programmatic or via `#activate`/`#toggle` — unlike `Triggered`,
    # which fires only on activation.
    def checked=(value : Bool) : Bool
      return value if @checked == value
      @checked = value
      emit ::Crysterm::Event::Toggled, value
      notify_changed
      value
    end

    # Whether this is a non-selectable separator rather than a real action
    # (Qt's `QAction#isSeparator`). Created via `Action.separator`.
    property? separator = false

    # Optional child actions forming a submenu (Qt's `QAction#menu`). When set, a
    # `Widget::Menu` shows this action with a `▶` marker and opens a nested menu
    # of these actions instead of activating it.
    getter menu : Array(Action)?

    # :ditto:
    notifying_setter menu, Array(Action)?

    # Whether this action opens a (non-empty) submenu.
    def menu? : Bool
      if s = @menu
        !s.empty?
      else
        false
      end
    end

    # Returns a separator action — a divider that menus/toolbars render as a rule
    # and skip during navigation.
    def self.separator : Action
      a = Action.new ""
      a.separator = true
      a
    end

    # The alternative keyboard shortcuts that activate this action (Qt's
    # `QAction::shortcuts`). Each entry is a `KeySequence`; the first is the
    # primary `#shortcut`.
    getter shortcuts = [] of KeySequence

    # The primary keyboard shortcut (Qt's `QAction::shortcut`) — the first of
    # `#shortcuts`, or `nil` if none is set.
    def shortcut : KeySequence?
      @shortcuts.first?
    end

    # Sets the primary (and only) shortcut from a single named key, e.g.
    # `action.shortcut = Tput::Key::CtrlB`.
    def shortcut=(key : KeyStroke) : KeyStroke
      self.shortcut = [key]
      key
    end

    # Sets the primary (and only) shortcut to *seq* (replacing any alternatives).
    def shortcut=(seq : KeySequence) : KeySequence
      self.shortcuts = [seq]
      seq
    end

    # Replaces the full list of alternative shortcuts (Qt's `setShortcuts`).
    def shortcuts=(list : Array(KeySequence)) : Array(KeySequence)
      return list if @shortcuts == list
      @shortcuts = list
      reinstall_shortcuts
      notify_changed
      list
    end

    # The active shortcut's context — when it fires relative to focus (Qt's
    # `QAction::shortcutContext`). Defaults to `Window`.
    getter shortcut_context : ShortcutContext = ShortcutContext::Window

    # :ditto:
    notifying_setter shortcut_context, ShortcutContext

    # Whether holding a shortcut key auto-repeats the action (Qt's
    # `QAction::autoRepeat`). When false, key auto-repeat events are ignored by
    # the shortcut dispatcher. On by default.
    property? auto_repeat = true

    # Relative importance hint (Qt's `QAction::priority`); advisory, consulted by
    # surfaces like a `Widget::ToolBar`.
    getter priority : Priority = Priority::Normal

    # :ditto:
    notifying_setter priority, Priority

    # Tip to show in status bar, if/when applicable
    property status_tip : String?

    # Tip to show in a popup on hover over the action, if/when applicable
    # (Qt's `QAction#toolTip`).
    property tool_tip : String?

    # Tip to show in a popup when broader help text / description is requested
    property whats_this : String?

    # Arbitrary user data (Qt's `QAction::data`/`setData`).
    property data : Data?

    # This property holds whether the action can be seen (e.g. in menus and toolbars) or is hidden.
    getter? visible = true

    # Sets `#visible`, emitting the granular `Event::VisibleChanged` (Qt's
    # `visibleChanged`) plus `Event::Changed`, only on a real change.
    def visible=(value : Bool) : Bool
      return value if @visible == value
      @visible = value
      emit ::Crysterm::Event::VisibleChanged, value
      notify_changed
      value
    end

    # The widgets currently presenting this action (Qt's
    # `QAction::associatedWidgets`) — the reverse of "added to". A `Widget::Menu`
    # or `Widget::ToolBar` registers itself here when the action is added to it
    # and removes itself when the action is removed, via `#associate`/`#dissociate`.
    # The same action may be presented by several widgets at once. A `Set` (not an
    # `Array`) because a widget can present an action only once; Crystal's `Set`
    # keeps insertion order, so iteration still follows add order.
    getter associated_widgets = Set(Widget).new

    # Registers *widget* as a host presenting this action. Idempotent — the `Set`
    # absorbs a repeat. Called by the host when the action is added to it; not
    # normally called directly.
    def associate(widget : Widget) : Nil
      @associated_widgets << widget
    end

    # Removes *widget* as a host (Qt's implicit `removeAction` bookkeeping).
    def dissociate(widget : Widget) : Nil
      @associated_widgets.delete widget
    end

    # Windows this action's shortcut accelerator is currently installed on,
    # mapped to the listener wrapper used to remove it again.
    @shortcut_wrappers = {} of ::Crysterm::Window => ::Crysterm::Event::KeyPress::Wrapper

    # Per-window half-entered chord: the leading keystrokes typed so far toward a
    # multi-stroke shortcut, awaiting completion. Empty/absent between chords.
    @shortcut_pending = {} of ::Crysterm::Window => KeySequence

    # The host widget supplied at install time, used to gate `Widget`-context
    # shortcuts on focus.
    @shortcut_host : Widget?

    # Notifies observers (menus, tool bars) that a display-affecting property
    # changed, by emitting `Event::Changed` (Qt's `QAction::changed()`). Emitted
    # only on an actual change, so redundant assignments don't trigger re-renders.
    protected def notify_changed : Nil
      emit ::Crysterm::Event::Changed
    end

    def initialize(@parent : EventHandler? = nil)
    end

    def initialize(
      @text : String,
      @parent : EventHandler? = nil,
      *,
      icon : String? = nil,
      icon_text : String? = nil,
      shortcut : KeyStroke | KeySequence | Nil = nil,
      shortcuts : Array(KeySequence)? = nil,
      shortcut_context : ShortcutContext = ShortcutContext::Window,
      checkable : Bool = false,
      checked : Bool = false,
      enabled : Bool = true,
      visible : Bool = true,
      auto_repeat : Bool = true,
      priority : Priority = Priority::Normal,
      status_tip : String? = nil,
      tool_tip : String? = nil,
      whats_this : String? = nil,
      menu : Array(Action)? = nil,
      data : Data? = nil,
    )
      # Assign ivars directly: at construction there are no observers yet, so the
      # event-emitting setters would be wasted work.
      @icon = icon
      @icon_text = icon_text
      @shortcut_context = shortcut_context
      @checkable = checkable
      @checked = checked
      @enabled = enabled
      @visible = visible
      @auto_repeat = auto_repeat
      @priority = priority
      @status_tip = status_tip
      @tool_tip = tool_tip
      @whats_this = whats_this
      @menu = menu
      @data = data
      if sc = shortcuts
        @shortcuts = sc
      elsif s = shortcut
        @shortcuts = s.is_a?(Array) ? [s] : [[s]]
      end
    end

    # Activates the action: emits *event* (defaulting to `Event::Triggered`).
    #
    # A **disabled** action does not fire its `Triggered` action — mirroring
    # Qt's `QAction::activate`, which gates the `triggered()` emission on
    # `isEnabled()`. Without this, a presenter that doesn't pre-check `#enabled`
    # before calling `#activate` (e.g. `Widget::ToolBar`'s button handler) would
    # run a greyed-out command. `Hovered` is *not* gated — hovering a disabled
    # entry still notifies (as in Qt), so status-tip/tooltip feedback keeps
    # working.
    #
    # For a **checkable** action a `Triggered` activation first flips `#checked?`
    # (emitting `Event::Toggled`), exactly as Qt's `activate(Trigger)` toggles
    # before emitting `triggered(checked)`. The post-toggle state is carried on
    # the `Triggered` event. Presenters therefore must NOT pre-toggle.
    def activate(event : OneOfEvents = Crysterm::Event::Triggered)
      if event == Crysterm::Event::Triggered
        return unless enabled
        self.checked = !checked? if checkable?
        emit Crysterm::Event::Triggered, checked?
      else
        emit Crysterm::Event::Hovered
      end
    end

    # Activates the action's `Triggered` behavior (Qt's `QAction::trigger`).
    def trigger
      activate Crysterm::Event::Triggered
    end

    # Emits the action's `Hovered` notification (Qt's `QAction::hover`).
    def hover
      activate Crysterm::Event::Hovered
    end

    # Flips a checkable action's `#checked?` (Qt's `QAction::toggle`), emitting
    # `Event::Toggled` but *not* `Triggered`. A no-op for non-checkable actions.
    def toggle
      self.checked = !checked? if checkable?
    end

    # The label with the `#icon` glyph prepended when set, e.g. `"📁 Open"`, else
    # just `#text`. Used by tool buttons and other compact surfaces.
    def display_label : String
      i = @icon
      i ? "#{i} #{@text}" : @text
    end

    # Display string for the primary shortcut, e.g. `"CtrlB"` or `"CtrlK, CtrlB"`
    # for a chord. Empty when no shortcut is set. Used by `Widget::Menu` for the
    # right-aligned accelerator column.
    def shortcut_text : String
      seq = shortcut
      return "" unless seq
      seq.map(&.to_s).join(", ")
    end

    # Whether keypress *e* on its own completes one of this action's
    # *single-keystroke* shortcuts (and the action is enabled). A convenience
    # predicate; multi-keystroke chords are driven through `#feed_shortcut`'s
    # state machine instead.
    def shortcut_matches?(e : ::Crysterm::Event::KeyPress) : Bool
      return false unless enabled
      k = e.key
      return false unless k
      @shortcuts.any? { |seq| seq.size == 1 && seq.first == k }
    end

    # Installs a window-level accelerator so this action fires when its shortcut
    # is pressed (Qt's shortcut activation). *host* is the widget the action is
    # presented in, used to gate `Widget`-context shortcuts on focus. Idempotent
    # per window; a no-op when the action has no shortcut.
    def install_shortcut(window : ::Crysterm::Window, host : Widget? = nil) : Nil
      @shortcut_host = host
      return if @shortcuts.empty?
      return if @shortcut_wrappers.has_key?(window)
      @shortcut_wrappers[window] = window.on(::Crysterm::Event::KeyPress) do |e|
        next if e.accepted?
        feed_shortcut window, e
      end
    end

    # Removes the accelerator installed by `#install_shortcut` for *window* and
    # drops any half-entered chord prefix for it.
    def uninstall_shortcut(window : ::Crysterm::Window) : Nil
      @shortcut_pending.delete window
      @shortcut_wrappers.delete(window).try do |w|
        window.off(::Crysterm::Event::KeyPress, w)
      end
    end

    # Feeds keypress *e* (on *window*) through the shortcut state machine,
    # supporting multi-keystroke chords (Qt's `QKeySequence`, e.g. "Ctrl+K,
    # Ctrl+B"). A single-stroke shortcut fires immediately; a chord advances a
    # per-window pending prefix and fires only once the whole sequence is entered.
    # A key that neither extends the pending prefix nor begins a fresh shortcut
    # clears the prefix (there is no inter-stroke timeout). A consumed key — a
    # fired shortcut or a held prefix — is `accept`ed so it does not also reach the
    # focused widget.
    private def feed_shortcut(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress) : Nil
      return if e.repeat? && !auto_repeat?
      return unless enabled
      return unless shortcut_active?
      k = e.key
      return unless k

      pending = @shortcut_pending[window]?
      # First try to extend a chord already in progress.
      return if pending && advance_shortcut(window, e, pending + [k])
      # Otherwise drop any stale prefix and try *k* as a fresh first stroke.
      @shortcut_pending.delete window if pending
      advance_shortcut window, e, [k]
    end

    # Matches *candidate* (the strokes entered so far) against the shortcut list:
    # fires on an exact match, holds (waits for the next stroke) on a proper
    # prefix, ignores otherwise. Returns whether *candidate* engaged a shortcut.
    private def advance_shortcut(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress, candidate : KeySequence) : Bool
      return false unless @shortcuts.any? { |seq| shortcut_prefix? seq, candidate }
      if @shortcuts.any? { |seq| seq == candidate }
        @shortcut_pending.delete window
        e.accept
        trigger
      else
        @shortcut_pending[window] = candidate # a proper prefix — await the rest
        e.accept
      end
      true
    end

    # Whether *candidate* is a leading prefix of *seq* (equal length counts).
    private def shortcut_prefix?(seq : KeySequence, candidate : KeySequence) : Bool
      return false if candidate.size > seq.size
      candidate.each_with_index { |k, i| return false unless seq[i] == k }
      true
    end

    # Re-registers accelerators on every window they were installed on, so a
    # later `#shortcut=`/`#shortcuts=` change takes effect on already-attached
    # windows.
    private def reinstall_shortcuts : Nil
      windows = @shortcut_wrappers.keys
      host = @shortcut_host
      windows.each do |w|
        uninstall_shortcut w
        install_shortcut w, host
      end
    end

    # Whether the shortcut may fire given its `#shortcut_context` and current
    # focus. `Window`/`Application` always fire while installed; `Widget` requires
    # one of the action's host widgets to hold focus; `WidgetWithChildren` also
    # accepts focus on a descendant of a host.
    private def shortcut_active? : Bool
      case shortcut_context
      in ShortcutContext::Application, ShortcutContext::Window
        true
      in ShortcutContext::Widget
        shortcut_hosts.any? &.focused?
      in ShortcutContext::WidgetWithChildren
        shortcut_hosts.any? { |h| h.focused? || descendant_focused?(h) }
      end
    end

    # The widgets that gate a `Widget`-context shortcut: the hosts the action was
    # added to, falling back to the host passed at `#install_shortcut` time (so
    # gating still works if an action was wired without being formally associated).
    private def shortcut_hosts : Enumerable(Widget)
      return @associated_widgets unless @associated_widgets.empty?
      (h = @shortcut_host) ? [h] : [] of Widget
    end

    # Whether the focused widget of *host*'s window is *host* itself or a
    # descendant of it (for `WidgetWithChildren` context).
    private def descendant_focused?(host : Widget) : Bool
      f = host.window?.try &.focused
      while f
        return true if f == host
        f = f.parent
      end
      false
    end
  end
end
