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
  end
end
