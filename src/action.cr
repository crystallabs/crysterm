require "event_handler"
require "tput"

module Crysterm
  # Represents a command invokable from multiple interfaces (menus, toolbar
  # buttons, keyboard shortcuts). Adding the same `Action` to several
  # menus/toolbars keeps them in sync automatically (e.g. a "Bold" toolbar
  # button and menu item share enabled/checked state).
  #
  # Recommended to create `Action`s as children of the window they're used in.
  # Add to `Menu` via `#<<(Action)` or `#add`, to `ToolBar` via `#add_action`,
  # or to `ActionGroup` via `#add_action`; an action must be added to a widget
  # before use.
  #
  # NOTE Actions are inspired by `QAction` (https://doc.qt.io/qt-6/qaction.html)
  class Action
    include EventHandler

    # Which notification `#activate` emits (Qt's `QAction::ActionEvent`:
    # https://doc.qt.io/qt-6/qaction.html#ActionEvent-enum).
    enum ActionEvent
      Trigger
      Hover
    end

    # A single keystroke in a shortcut — a named `Tput::Key` (the enum already
    # encodes the `Ctrl*`/`Shift*`/`Alt*` chord members, e.g. `CtrlB`, `CtrlUp`).
    alias KeyStroke = ::Tput::Key

    # An ordered sequence of keystrokes forming one shortcut (Qt's `QKeySequence`),
    # e.g. `[Tput::Key::CtrlK, Tput::Key::CtrlB]` for the chord "Ctrl+K, Ctrl+B".
    # A plain single-key shortcut is a one-element sequence.
    alias KeySequence = Array(KeyStroke)

    # User payload carried on the action (Qt's `QAction::data`) — typically an id
    # or command name, read back in a `Triggered` handler. For a richer payload,
    # carry an id here and look the object up, or subclass `Action`. Same union
    # `Mixin::Data#data` (any widget's `#data`) uses — see `Crysterm::UserData`.
    alias Data = ::Crysterm::UserData

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
    # actual change. When *event* is given (a granular event class such as
    # `Event::EnabledChanged`), that event is emitted with the new value *before*
    # `notify_changed`; the emit-before-notify_changed order matters — see the
    # granular callers (enabled/checkable/checked/visible) below.
    private macro notifying_setter(name, type, event = nil)
      def {{ name.id }}=(value : {{ type }}) : {{ type }}
        return value if @{{ name.id }} == value
        @{{ name.id }} = value
        {% if event %} emit {{ event }}, value {% end %}
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
    notifying_setter enabled, Bool, ::Crysterm::Event::EnabledChanged

    # Whether the action has an on/off checked state (Qt's `QAction#checkable`),
    # e.g. a toggleable "Word Wrap" menu entry. `Widget::Menu` draws a
    # `[x]`/`[ ]` marker and flips `#checked?` on activation.
    getter? checkable = false

    # Sets `#checkable`, emitting `Event::CheckableChanged` plus `Event::Changed`,
    # only on a real change.
    notifying_setter checkable, Bool, ::Crysterm::Event::CheckableChanged

    # Current checked state; only meaningful when `#checkable?`.
    getter? checked = false

    # Sets `#checked`, emitting `Event::Toggled` (Qt's `toggled(bool)`) plus
    # `Event::Changed`, only on a real change. `Toggled` fires on any checked
    # change; `Triggered` only on activation.
    notifying_setter checked, Bool, ::Crysterm::Event::Toggled

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
    notifying_setter visible, Bool, ::Crysterm::Event::VisibleChanged

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

    # Shared per-window shortcut dispatch state (mirroring Qt's `QShortcutMap`):
    # every action installed on a window, the window's single half-entered chord
    # prefix, and the one window-level `KeyPress` subscription feeding them all.
    # One shared arbiter — rather than one handler per action — so that a chord
    # in progress consumes its completing stroke ahead of any other action's
    # fresh single-stroke match, and so that a key consumed elsewhere still
    # clears the prefix. See `Action.dispatch_shortcut`.
    private class ShortcutMap
      # Installed actions, in installation order (which breaks ties between
      # identical sequences: the earlier-installed action fires).
      getter actions = [] of Action

      # The half-entered chord: leading keystrokes typed so far toward one or
      # more multi-stroke shortcuts. Empty between chords.
      property pending : KeySequence = KeySequence.new

      # Reusable buffer for the candidate sequence built on every keypress by
      # `Action.dispatch_shortcut`/`.advance_shortcut`, so matching a shortcut
      # allocates nothing per keystroke. Distinct from `#pending` — `pending`
      # is only ever updated by copying this buffer's contents into it, never
      # by aliasing it, so reusing it across calls is safe.
      getter scratch = KeySequence.new

      # The one window-level `KeyPress` subscription driving
      # `Action.dispatch_shortcut` for this window.
      getter subscription = ::Crysterm::Subscription.new
    end

    # The shared per-window shortcut arbiters: created on the first
    # `#install_shortcut` for a window, dropped again when its last action is
    # uninstalled.
    @@shortcut_maps = {} of ::Crysterm::Window => ShortcutMap

    # Windows this action is currently registered on (in the window's shared
    # `ShortcutMap`).
    @shortcut_windows = Set(::Crysterm::Window).new

    # Per-window host widget supplied at install time, used to gate
    # `Widget`-context shortcuts on focus. Keyed by window so an action installed
    # on several windows keeps each window's own host.
    @shortcut_host_by_window = {} of ::Crysterm::Window => Widget

    # Notifies observers (menus, tool bars) that a display-affecting property
    # changed (Qt's `QAction::changed()`).
    protected def notify_changed : Nil
      emit ::Crysterm::Event::Changed
    end

    # The `ActionGroup` this action currently belongs to, if any (Qt's
    # `QAction::actionGroup`). Set by `ActionGroup#add_action`/`#remove_action`;
    # not meant to be assigned directly. Consulted by `#activate` to suppress
    # the off-toggle Qt applies when re-triggering an exclusive group's checked
    # member.
    protected property group : ActionGroup?

    def initialize(@parent : EventHandler? = nil)
    end

    def initialize(
      @text : String,
      @parent : EventHandler? = nil,
      *,
      icon : String? = nil,
      icon_text : String? = nil,
      shortcut : KeyStroke | KeySequence? = nil,
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
    # state — presenters must NOT pre-toggle. Exception: re-triggering the
    # already-checked member of an exclusive `ActionGroup` does NOT flip it off
    # (Qt's `QAction::activate` suppresses exactly this off-toggle so a radio
    # group always keeps a selection); `#toggle` and `#checked=` are unaffected
    # and can still uncheck it programmatically.
    def activate(event : ActionEvent = :trigger)
      case event
      in .trigger?
        return unless enabled?
        if checkable?
          if checked? && (g = @group) && g.exclusive?
            # Exclusive group, re-triggering the checked member: Qt keeps it checked.
          else
            self.checked = !checked?
          end
        end
        emit Crysterm::Event::Triggered, checked?
      in .hover?
        emit Crysterm::Event::Hovered
      end
    end

    # Activates the action's `Triggered` behavior (Qt's `QAction::trigger`).
    def trigger
      activate ActionEvent::Trigger
    end

    # Emits the action's `Hovered` notification (Qt's `QAction::hover`).
    def hover
      activate ActionEvent::Hover
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
    # `Action.dispatch_shortcut`'s state machine instead.
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
    #
    # All actions installed on a window share one `ShortcutMap` (a single
    # window-level `KeyPress` handler), so their sequences are matched together
    # — see `Action.dispatch_shortcut`.
    def install_shortcut(window : ::Crysterm::Window, host : Widget? = nil) : Nil
      if host
        @shortcut_host_by_window[window] = host
      else
        @shortcut_host_by_window.delete window
      end
      return if @shortcuts.empty?
      return unless @shortcut_windows.add? window
      map = @@shortcut_maps[window]? || begin
        m = @@shortcut_maps[window] = ShortcutMap.new
        m.subscription.on(window, ::Crysterm::Event::KeyPress) do |e|
          Action.dispatch_shortcut window, e
        end
        m
      end
      map.actions << self
    end

    # Removes this action from the shared accelerator installed by
    # `#install_shortcut` for *window*. A half-entered chord prefix is dropped
    # unless a still-installed action can still complete it; the shared
    # `KeyPress` handler itself goes away with the window's last action.
    def uninstall_shortcut(window : ::Crysterm::Window) : Nil
      @shortcut_host_by_window.delete window
      return unless @shortcut_windows.delete window
      map = @@shortcut_maps[window]? || return
      map.actions.delete self
      unless map.pending.empty? || map.actions.any?(&.shortcut_continues?(map.pending))
        map.pending.clear
      end
      if map.actions.empty?
        map.subscription.off
        @@shortcut_maps.delete window
      end
    end

    # Feeds keypress *e* (on *window*) through the window's shared shortcut
    # state machine, supporting multi-keystroke chords (Qt's `QKeySequence`,
    # e.g. "Ctrl+K, Ctrl+B"). A single-stroke shortcut fires immediately; a
    # chord advances the window's pending prefix and fires only once fully
    # entered.
    #
    # The window's actions are matched *together* (Qt's `QShortcutMap`):
    # while a chord is in progress, its next stroke is first tried as a chord
    # continuation across every installed sequence, so another action's fresh
    # single-stroke match cannot steal it (a Ctrl+S action does not preempt the
    # Ctrl+S completing Ctrl+K, Ctrl+S). A stroke that instead breaks the chord
    # drops the prefix and is re-tried as a fresh first stroke, not swallowed.
    #
    # A key that neither extends the prefix nor begins a fresh shortcut clears
    # it (no inter-stroke timeout) — and so does a key already `accept`ed by an
    # earlier handler (the focused widget's key walk, `KeyShortcuts`, …), which
    # can only ever clear, never fire. A consumed key is `accept`ed so it
    # doesn't also reach the focused widget.
    protected def self.dispatch_shortcut(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress) : Nil
      map = @@shortcut_maps[window]? || return
      if e.accepted?
        map.pending.clear
        return
      end
      k = e.key
      unless k
        # A plain character (no named `#key`): typing text between a chord's
        # strokes must not leave the prefix live.
        map.pending.clear
        return
      end
      s = map.scratch
      unless map.pending.empty?
        # A chord in progress owns the stroke: try it as a continuation first.
        s.clear
        s.concat map.pending
        s << k
        return if advance_shortcut(window, map, e, s)
        # The stroke broke the chord: drop the prefix and re-try the same
        # stroke as a fresh first stroke below.
        map.pending.clear
      end
      s.clear
      s << k
      advance_shortcut window, map, e, s
    end

    # Matches *candidate* (the strokes entered so far) against every installed
    # action's sequences at once: an exact match fires the first action (in
    # installation order) whose gates pass — an exact match deliberately beats a
    # proper-prefix hold when one action's full sequence is another's chord
    # prefix (Qt's behavior: `[CtrlS]` fires even while `[CtrlS, CtrlX]` is also
    # registered). Otherwise a proper prefix of any passing action holds
    # *candidate* as the window's pending chord. Returns whether *candidate*
    # engaged a shortcut; when it did, the event is `accept`ed.
    private def self.advance_shortcut(window : ::Crysterm::Window, map : ShortcutMap, e : ::Crysterm::Event::KeyPress, candidate : KeySequence) : Bool
      holds = false
      map.actions.each do |a|
        exact, prefix = a.shortcut_candidate window, e, candidate
        if exact
          map.pending.clear
          e.accept
          a.trigger
          return true
        end
        holds ||= prefix
      end
      if holds
        map.pending.clear
        map.pending.concat candidate # a proper prefix — await the rest
        e.accept
      end
      holds
    end

    # How *candidate* (the strokes entered so far) relates to this action's
    # shortcut list right now: `{exact, prefix}` — whether it exactly matches a
    # sequence, and whether it is a proper prefix of a longer one. Both are
    # `false` whenever the action may not fire at all: disabled, a dropped
    # auto-repeat, or out of its focus context. The (possibly focus-walking)
    # `#shortcut_active?` probe runs only after a cheap key-list match, so
    # irrelevant keys skip it.
    protected def shortcut_candidate(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress, candidate : KeySequence) : {Bool, Bool}
      none = {false, false}
      exact = false
      prefix = false
      @shortcuts.each do |seq|
        next unless shortcut_prefix? seq, candidate
        if seq.size == candidate.size
          exact = true
        else
          prefix = true
        end
      end
      return none unless exact || prefix
      return none if (e.repeat? && !auto_repeat?) || !enabled?
      return none unless shortcut_active? window
      {exact, prefix}
    end

    # Whether *candidate* is a proper prefix of one of this action's sequences —
    # a chord in progress that further strokes could still complete.
    protected def shortcut_continues?(candidate : KeySequence) : Bool
      @shortcuts.any? { |seq| seq.size > candidate.size && shortcut_prefix?(seq, candidate) }
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
      # Union, not just `@shortcut_windows`: an action added to a window while
      # `@shortcuts` was empty has a host recorded there but no registration, and
      # must still be revisited so its new shortcut goes live.
      windows = (@shortcut_windows.to_a | hosts.keys)
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
