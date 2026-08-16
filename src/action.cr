require "event_handler"
require "tput"

require "./mnemonic"

module Crysterm
  # Represents a command invokable from multiple interfaces (menus, toolbar
  # buttons, keyboard shortcuts). Adding the same `Action` to several
  # menus/toolbars keeps them in sync automatically (e.g. a "Bold" toolbar
  # button and menu item share enabled/checked state).
  #
  # Pass `parent:` to give the action an owner widget: it is installed on that
  # widget (`Widget#add_action`), so its keyboard shortcut goes live on the
  # widget's window, follows the widget across attach/detach, and goes away with
  # it. That is ownership only — the parent presents nothing. To *show* the
  # action, add it to a `Menu` via `#<<(Action)`/`#add`, to a `ToolBar` via
  # `#add_action`, or to an `ActionGroup` via `#add_action`.
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
    #
    # A no-op on a non-checkable action, matching Qt's `QAction::setChecked` —
    # and matching `#toggle`, which has always no-opped there: an action with no
    # on/off state must never report one.
    def checked=(value : Bool) : Bool
      return value unless checkable?
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

    # Sets the primary (and only) shortcut from Qt's textual key-sequence
    # syntax (`QKeySequence("Ctrl+B")`): chords separated by `+` within a
    # stroke, strokes separated by `,` —
    #
    # ```
    # action.shortcut = "Ctrl+B"
    # action.shortcut = "Ctrl+K, Ctrl+B"
    # action.shortcut = "F5"
    # ```
    #
    # Raises `ArgumentError` on a stroke that maps to no `Tput::Key` member —
    # see `Action.parse_key_sequence`.
    def shortcut=(spec : String) : String
      self.shortcut = Action.parse_key_sequence(spec)
      spec
    end

    # Parses **shortcut** syntax — Qt's `QKeySequence` textual form — into a
    # `KeySequence`: comma-separated strokes, each a `+`-joined chord resolved
    # against the `Tput::Key` members (`"Ctrl+B"` → `CtrlB`, `"F5"` → `F5`,
    # `"Ctrl+PgDn"` → `CtrlPageDown`). Common short names are accepted
    # (`Esc`, `Del`, `Ins`, `PgUp`, `PgDn`, `Dn`, `Return`, `Ret`), as is the
    # caret chord spelling (`"^X"` → `CtrlX`). Raises `ArgumentError` on an
    # unrecognized stroke, naming it.
    #
    # This is one of Crysterm's two key vocabularies. The other is the
    # **display-label** one read by `Event::KeyPress.parse` — the terse
    # spellings a key bar prints (`"^X"`, `"PgDn"`) — which is lenient
    # (`nil` on anything unknown) and describes what is *shown*, not what is
    # *bound*. The overlapping spellings (caret chords, short key names) parse
    # the same in both; only this one understands `+`-chords, `,`-sequences and
    # Qt's long names, and only this one raises.
    def self.parse_key_sequence(spec : String) : KeySequence
      spec.split(',').map { |stroke| parse_key_stroke(stroke.strip) }
    end

    # One stroke of `.parse_key_sequence`: `"Ctrl+Shift+F5"` → the matching
    # `Tput::Key` member.
    def self.parse_key_stroke(stroke : String) : KeyStroke
      stroke = stroke.strip
      # Caret chord (the display vocabulary's `^X`) — rewritten to the `+` form
      # so the one resolver below handles both spellings.
      if stroke.size == 2 && stroke[0] == '^'
        stroke = "Ctrl+#{stroke[1]}"
      end
      name = stroke.split('+').join do |part|
        part = part.strip
        # Qt / display spelling → Tput::Key member-fragment spelling.
        case part.downcase
        when "esc"            then "Escape"
        when "del"            then "Delete"
        when "ins"            then "Insert"
        when "pgup"           then "PageUp"
        when "pgdn", "pgdown" then "PageDown"
        when "dn"             then "Down"
        when "return", "ret"  then "Enter"
        else
          # A single letter upcases (`b` → `B`); multi-char parts keep their
          # tail (`PageDown` stays `PageDown`, `ctrl` → `Ctrl`).
          part.size == 1 ? part.upcase : (part[0].upcase + part[1..])
        end
      end
      ::Tput::Key.parse?(name) ||
        raise ArgumentError.new("Unrecognized key stroke #{stroke.inspect} (no Tput::Key member #{name.inspect})")
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
    # `ActionAccelerators`).
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

    # The widget owning this action (Qt's `QObject::parent`), or `nil` for a
    # free-standing one. Set at construction; the action is installed on it via
    # `Widget#add_action`.
    getter parent : Widget?

    def initialize(parent : Widget? = nil)
      adopt parent
    end

    def initialize(
      @text : String,
      parent : Widget? = nil,
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
      # Last, so the shortcut set above is already in place when the parent
      # installs the accelerator.
      adopt parent
    end

    # Records *parent* as the owner and installs this action on it, so the
    # shortcut becomes active on the parent's window and follows it across
    # attach/detach. No-op without a parent.
    private def adopt(parent : Widget?) : Nil
      return unless parent
      @parent = parent
      parent.add_action self
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
    #
    # Internal (Qt keeps `QAction::activate` out of the public API): user code
    # calls `#trigger`/`#hover`, and the accelerator dispatcher calls those too.
    protected def activate(event : ActionEvent = :trigger)
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
        emit Crysterm::Event::Triggered, checked?, self
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

    # The label with `#icon` prepended when set (e.g. `"📁 Open"`), else
    # `#text` — with any Qt-style `&` mnemonic marker resolved away
    # (`"&New"` shows as `"New"`, `"&&"` as `"&"`): mnemonics are menu
    # presentation, and Qt likewise strips them on tool-bar buttons and other
    # plain label sites. Menus render the marked letter underlined instead
    # (see `Crysterm::Mnemonic` and `Widget::Menu`).
    def display_label : String
      i = @icon
      text = ::Crysterm::Mnemonic.parse(@text)[0]
      i ? "#{i} #{text}" : text
    end

    # The label's Qt-style `&` mnemonic letter (downcased), or `nil` when none
    # is marked. In an open menu, pressing the bare letter activates this
    # action's row.
    def mnemonic : Char?
      ::Crysterm::Mnemonic.parse(@text)[1]
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
