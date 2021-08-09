module Crysterm
  class Action < Object
    event Triggered
    event Hovered

    property text = ""
    property enabled = true

    property shortcut : Tput::Key? # Needs to be `KeySequence?` later
    property status_tip : String?
    property tool_tip : String?
    property whats_this : String?

    def initialize(
      @parent : Crysterm::Object? = nil
    )
    end

    def initialize(
      @parent : Crysterm::Object? = nil,
      event : Triggered.class | Hovered.class = Triggered,
      &block : ::Proc(::Crysterm::Action::Triggered, ::Nil)
    )
      on event, block
    end

    def initialize(
      @text,
      @parent : Crysterm::Object? = nil
    )
    end

    def initialize(
      @text,
      @parent : Crysterm::Object? = nil,
      event : Triggered.class | Hovered.class = Triggered,
      &block : ::Proc(::Crysterm::Action::Triggered, ::Nil)
    )
      on event, block
    end

    # def activate(event : ActionEvent = ActionEvent::Triggered)
    def activate(event : Triggered.class | Hovered.class = Triggered)
      emit event
    end
  end
end
