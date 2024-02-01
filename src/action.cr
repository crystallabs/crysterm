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

    # Unused for now, reenable later
    # Icon of action
    # property icon : Icon?

    # Text / label of action
    property text : String = ""

    # Action enabled?
    property enabled = true

    # Keyboard shortcut
    # TODO Needs to become proper `KeySequence?` later, so that it can trigger on a sequence
    # of key presses (E.g. Ctrl+a, d)
    alias KeySequence = Tput::Key
    property shortcut : KeySequence?

    # Tip to show in status bar, if/when applicable
    property status_tip : String?

    # Tip to show in a popup on hover over the action, if/when applicable
    setter tool_tip : String?

    # Tip to show in a popup when broader help text / description is requested
    property whats_this : String?

    # This property holds whether the action can be seen (e.g. in menus and toolbars) or is hidden.
    property? visible = true

    def initialize(
      @parent : EventHandler? = nil
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
      @parent : EventHandler? = nil
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

    # Activates the action
    def activate(event : OneOfEvents = Crysterm::Event::Triggered)
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
