require "event_handler"
require "tput"

module Crysterm
  # Represents a command invokable from multiple interfaces (menus, toolbar
  # buttons, keyboard shortcuts). Adding the same `Action` to several
  # menus/toolbars keeps them in sync automatically (e.g. a "Bold" toolbar
  # button and menu item share enabled/checked state).
  #
  # Recommended to create `Action`s as children of the window they're used in.
  # Add to `Widget`s via `#addAction` or `<<(Action)`; an action must be added
  # to a widget before use.
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

    # User payload carried on the action (Qt's `QAction::data`) — typically an id
    # or command name, read back in a `Triggered` handler. For a richer payload,
    # carry an id here and look the object up, or subclass `Action`.
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

    # Defines a `name=` setter that assigns and emits `Event::Changed` only on an
    # actual change. Properties that also emit a granular event
    # (enabled/checkable/checked/visible) define their setters explicitly below.
    private macro notifying_setter(name, type)
      def {{ name.id }}=(value : {{ type }}) : {{ type }}
        return value if @{{ name.id }} == value
        @{{ name.id }} = value
        notify_changed
        value
      end
    end

    # The action's icon (Qt's `QAction::icon`). A terminal has no pixmap, so
    # this is a Unicode glyph or short string (`"📁"`, `"✂"`, `"▶"`) rendered
    # before the label by menus and tool buttons.
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
    getter? enabled = true

    # Sets `#enabled`, emitting `Event::EnabledChanged` plus `Event::Changed`,
    # only on a real change.
    def enabled=(value : Bool) : Bool
      return value if @enabled == value
      @enabled = value
      emit ::Crysterm::Event::EnabledChanged, value
      notify_changed
      value
    end

    # Whether the action has an on/off checked state (Qt's `QAction#checkable`),
    # e.g. a toggleable "Word Wrap" menu entry. `Widget::Menu` draws a
    # `[x]`/`[ ]` marker and flips `#checked?` on activation.
    getter? checkable = false

    # Sets `#checkable`, emitting `Event::CheckableChanged` plus `Event::Changed`,
    # only on a real change.
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
    # `Event::Changed`, only on a real change. `Toggled` fires on any checked
    # change; `Triggered` only on activation.
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

    # Optional child actions forming a submenu (Qt's `QAction#menu`). When set,
    # `Widget::Menu` shows a `▶` marker and opens a nested menu instead of activating.
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
    # `QAction::autoRepeat`). When false, auto-repeat events are ignored by the
    # shortcut dispatcher.
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

    # Sets `#visible`, emitting `Event::VisibleChanged` plus `Event::Changed`,
    # only on a real change.
    def visible=(value : Bool) : Bool
      return value if @visible == value
      @visible = value
      emit ::Crysterm::Event::VisibleChanged, value
      notify_changed
      value
    end

    # The widgets currently presenting this action (Qt's
    # `QAction::associatedWidgets`), in insertion order. A `Widget::Menu`/
    # `Widget::ToolBar` registers/unregisters itself via `#associate`/`#dissociate`.
    getter associated_widgets = Set(Widget).new

    # Registers *widget* as a host presenting this action. Idempotent. Called by
    # the host when the action is added to it.
    def associate(widget : Widget) : Nil
      @associated_widgets << widget
    end

    # Removes *widget* as a host.
    def dissociate(widget : Widget) : Nil
      @associated_widgets.delete widget
    end

    # Windows this action's shortcut accelerator is installed on, mapped to the
    # `Subscription` that removes it again.
    @shortcut_subs = {} of ::Crysterm::Window => ::Crysterm::Subscription

    # Per-window half-entered chord: the leading keystrokes typed so far toward a
    # multi-stroke shortcut. Empty/absent between chords.
    @shortcut_pending = {} of ::Crysterm::Window => KeySequence

    # Per-window host widget supplied at install time, used to gate
    # `Widget`-context shortcuts on focus. Keyed by window so an action installed
    # on several windows keeps each window's own host.
    @shortcut_host_by_window = {} of ::Crysterm::Window => Widget

    # Notifies observers (menus, tool bars) that a display-affecting property
    # changed (Qt's `QAction::changed()`).
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
      # No observers exist yet, so assign directly rather than via the emitting setters.
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
    # A disabled action does not fire `Triggered`; `Hovered` is not gated, so a
    # disabled entry still gives tooltip feedback. A checkable action flips
    # `#checked?` before emitting `Triggered`, which carries the post-toggle
    # state — presenters must NOT pre-toggle.
    def activate(event : OneOfEvents = Crysterm::Event::Triggered)
      if event == Crysterm::Event::Triggered
        return unless enabled?
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

    # The label with `#icon` prepended when set (e.g. `"📁 Open"`), else `#text`.
    def display_label : String
      i = @icon
      i ? "#{i} #{@text}" : @text
    end

    # Display string for the primary shortcut, e.g. `"CtrlB"` or `"CtrlK, CtrlB"`
    # for a chord. Empty when no shortcut is set.
    def shortcut_text : String
      seq = shortcut
      return "" unless seq
      seq.map(&.to_s).join(", ")
    end

    # Whether keypress *e* alone completes one of this action's single-keystroke
    # shortcuts (and the action is enabled). Multi-keystroke chords go through
    # `#feed_shortcut`'s state machine instead.
    def shortcut_matches?(e : ::Crysterm::Event::KeyPress) : Bool
      return false unless enabled?
      k = e.key
      return false unless k
      @shortcuts.any? { |seq| seq.size == 1 && seq.first == k }
    end

    # Installs a window-level accelerator so this action fires when its shortcut
    # is pressed. *host* is the widget the action is presented in, used to gate
    # `Widget`-context shortcuts on focus. Idempotent per window; no-op without
    # a shortcut.
    def install_shortcut(window : ::Crysterm::Window, host : Widget? = nil) : Nil
      if host
        @shortcut_host_by_window[window] = host
      else
        @shortcut_host_by_window.delete window
      end
      return if @shortcuts.empty?
      return if @shortcut_subs.has_key?(window)
      sub = @shortcut_subs[window] = ::Crysterm::Subscription.new
      sub.on(window, ::Crysterm::Event::KeyPress) do |e|
        next if e.accepted?
        feed_shortcut window, e
      end
    end

    # Removes the accelerator installed by `#install_shortcut` for *window* and
    # drops any half-entered chord prefix for it.
    def uninstall_shortcut(window : ::Crysterm::Window) : Nil
      @shortcut_pending.delete window
      @shortcut_host_by_window.delete window
      @shortcut_subs.delete(window).try &.off
    end

    # Feeds keypress *e* (on *window*) through the shortcut state machine,
    # supporting multi-keystroke chords (Qt's `QKeySequence`, e.g. "Ctrl+K,
    # Ctrl+B"). A single-stroke shortcut fires immediately; a chord advances a
    # per-window pending prefix and fires only once fully entered. A key that
    # neither extends the prefix nor begins a fresh shortcut clears it (no
    # inter-stroke timeout). A consumed key is `accept`ed so it doesn't also
    # reach the focused widget.
    private def feed_shortcut(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress) : Nil
      # A dropped auto-repeat or a disabled action neither extends nor begins a
      # shortcut, so it clears any half-entered prefix.
      if (e.repeat? && !auto_repeat?) || !enabled?
        @shortcut_pending.delete window
        return
      end
      k = e.key
      unless k
        # Likewise a plain character (no named `#key`): typing text between a
        # chord's strokes must not leave the prefix live.
        @shortcut_pending.delete window
        return
      end

      pending = @shortcut_pending[window]?
      # Cheap key-match reject, hoisted ahead of the focus-walking
      # `shortcut_active?` probe: an irrelevant key clears any stale prefix and
      # triggers nothing either way, so the walk can be skipped for it.
      extends_pending =
        if p = pending
          @shortcuts.any? { |seq| seq.size > p.size && shortcut_prefix?(seq, p) && seq[p.size] == k }
        else
          false
        end
      begins_new = @shortcuts.any? { |seq| seq.first? == k }
      unless extends_pending || begins_new
        @shortcut_pending.delete window if pending
        return
      end

      # The key could match; now gate on focus context. A press out of its
      # focus context still clears any half-entered prefix.
      unless shortcut_active? window
        @shortcut_pending.delete window
        return
      end

      # First try to extend a chord already in progress.
      if extends_pending && (p = pending)
        return if advance_shortcut(window, e, p + [k])
      end
      # Otherwise drop any stale prefix and try *k* as a fresh first stroke.
      @shortcut_pending.delete window if pending
      advance_shortcut window, e, [k] if begins_new
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
    # later `#shortcut=`/`#shortcuts=` change takes effect on attached windows.
    private def reinstall_shortcuts : Nil
      hosts = @shortcut_host_by_window.dup
      # Union, not just `@shortcut_subs.keys`: an action added to a window while
      # `@shortcuts` was empty has a host recorded there but no subscription, and
      # must still be revisited so its new shortcut goes live.
      windows = (@shortcut_subs.keys | hosts.keys)
      windows.each do |w|
        uninstall_shortcut w
        install_shortcut w, hosts[w]?
      end
    end

    # Whether the shortcut may fire given `#shortcut_context` and current focus.
    # `Window`/`Application` always fire; `Widget` requires a host widget to
    # hold focus; `WidgetWithChildren` also accepts focus on a host's descendant.
    private def shortcut_active?(window : ::Crysterm::Window) : Bool
      case shortcut_context
      in ShortcutContext::Application, ShortcutContext::Window
        true
      in ShortcutContext::Widget
        host_focused?(window, &.focused?)
      in ShortcutContext::WidgetWithChildren
        host_focused?(window) { |h| h.focused? || descendant_focused?(h) }
      end
    end

    # Whether any gating host of a `Widget`-context shortcut on *window* satisfies
    # the block. The gating hosts are this action's associated widgets living on
    # *window* (one focused on another window must not fire the shortcut), falling
    # back to the host recorded at `#install_shortcut` time when none is.
    # Evaluates in place — this runs on every keypress per Widget-context action.
    private def host_focused?(window : ::Crysterm::Window, & : Widget -> Bool) : Bool
      any_on_window = false
      @associated_widgets.each do |w|
        next unless w.window? == window
        any_on_window = true
        return true if yield w
      end
      # Fall back to the install-time host only when no associated widget is on this window.
      return false if any_on_window
      (h = @shortcut_host_by_window[window]?) ? (yield h) : false
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
