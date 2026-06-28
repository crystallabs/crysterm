require "event_handler"

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

    # Defines a `name=` setter that assigns only on an actual change and then
    # calls `#notify_changed` (emitting `Event::Changed`), so observers (menus,
    # toolbars) refresh. Skipping the emit on a redundant assignment is what keeps
    # repeated/no-op assignments from triggering needless re-renders. Shared by
    # all the display-affecting `Action` properties; their getters stay declared
    # separately (some are `getter`, some `getter?`).
    private macro notifying_setter(name, type)
      def {{ name.id }}=(value : {{ type }}) : {{ type }}
        return value if @{{ name.id }} == value
        @{{ name.id }} = value
        notify_changed
        value
      end
    end

    # Unused for now, reenable later
    # Icon of action
    # property icon : Icon?

    # Text / label of action
    getter text : String = ""

    # :ditto:
    notifying_setter text, String

    # Action enabled?
    getter enabled = true

    # :ditto:
    notifying_setter enabled, Bool

    # Whether the action has an on/off checked state (Qt's `QAction#checkable`),
    # e.g. a toggleable "Word Wrap" menu entry. A `Widget::Menu` draws a
    # `[x]`/`[ ]` marker for checkable actions and flips `#checked?` when they are
    # activated.
    getter? checkable = false

    # :ditto:
    notifying_setter checkable, Bool

    # Current checked state; only meaningful when `#checkable?`.
    getter? checked = false

    # :ditto:
    notifying_setter checked, Bool

    # Whether this is a non-selectable separator rather than a real action
    # (Qt's `QAction#isSeparator`). Created via `Action.separator`.
    property? separator = false

    # Optional child actions forming a submenu (Qt's `QAction#menu`). When set, a
    # `Widget::Menu` shows this action with a `▶` marker and opens a nested menu
    # of these actions instead of activating it.
    getter submenu : Array(Action)?

    # :ditto:
    notifying_setter submenu, Array(Action)?

    # Whether this action opens a (non-empty) submenu.
    def submenu? : Bool
      if s = @submenu
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

    # Keyboard shortcut
    # TODO Needs to become proper `KeySequence?` later, so that it can trigger on a sequence
    # of key presses (E.g. Ctrl+a, d)
    alias KeySequence = Tput::Key
    getter shortcut : KeySequence?

    # :ditto:
    notifying_setter shortcut, KeySequence?

    # Tip to show in status bar, if/when applicable
    property status_tip : String?

    # Tip to show in a popup on hover over the action, if/when applicable
    # (Qt's `QAction#toolTip`).
    property tool_tip : String?

    # Tip to show in a popup when broader help text / description is requested
    property whats_this : String?

    # This property holds whether the action can be seen (e.g. in menus and toolbars) or is hidden.
    getter? visible = true

    # :ditto:
    notifying_setter visible, Bool

    # Notifies observers (menus, tool bars) that a display-affecting property
    # changed, by emitting `Event::Changed` (Qt's `QAction::changed()`). Emitted
    # only on an actual change, so redundant assignments don't trigger re-renders.
    protected def notify_changed : Nil
      emit ::Crysterm::Event::Changed
    end

    def initialize(
      @parent : EventHandler? = nil,
      # NOTE Passing a block directly to the initializer would be convenient, but because
      # it also requires specifying which event to trigger on (thus adding 2 new params),
      # it gets unwieldy quickly. So let's stay with the basic interface for now.
      # Add the action to execute after creation, simply with:  obj.on(Triggered) { block }
      # event : OneOfEvents = Crysterm::Event::Triggered,
      # &block : ::Proc(Crysterm::Event::Triggered, ::Nil)
    )
      # on event, block
    end

    def initialize(
      @text,
      @parent : EventHandler? = nil,
    )
    end

    # XXX Blocks for initializers are currently disabled. But when we get to enabling them,
    # use the same approach that kdebindings' qtruby bindings for Qt4 took to make them
    # work.
    # def initialize(
    #  @text,
    #  @parent : Crysterm::Object? = nil
    #  event : OneOfEvents = Crysterm::Event::Triggered,
    #  &block : ::Proc(Event::Triggered, ::Nil)
    # )
    #  on event, block
    # end

    # Alternatively, for overloads with and without a block:
    # def foo(&block : Proc(Nil)); foo(block); end; def foo(proc : Proc(Nil)? = nil); proc.try &.call; end; foo; foo { "hello" }

    # def activate(event : ActionEvent = ActionEvent::Event::Triggered)

    # Activates the action: emits *event* (defaulting to `Event::Triggered`).
    #
    # A **disabled** action does not fire its `Triggered` action — mirroring
    # Qt's `QAction::activate`, which gates the `triggered()` emission on
    # `isEnabled()`. Without this, a presenter that doesn't pre-check `#enabled`
    # before calling `#activate` (e.g. `Widget::ToolBar`'s button handler) would
    # run a greyed-out command. `Hovered` is *not* gated — hovering a disabled
    # entry still notifies (as in Qt), so status-tip/tooltip feedback keeps
    # working.
    def activate(event : OneOfEvents = Crysterm::Event::Triggered)
      return if event == Crysterm::Event::Triggered && !enabled
      emit event
    end

    # NOTE Disabled for now so that always #activate(Event) is used
    # # Activates the action
    # def trigger
    #  activate Crysterm::Event::Triggered
    # end

    # # Activates the action
    # def hover
    #  activate Crysterm::Event::Hovered
    # end
  end
end
