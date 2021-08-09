module Crysterm
  class Action < Object
    event Event::Triggered
    event Event::Hovered

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
      event : Event::Triggered.class | Event::Hovered.class = Event::Triggered,
      &block : ::Proc(::Crysterm::Action::Event::Triggered, ::Nil)
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
      event : Event::Triggered.class | Event::Hovered.class = Event::Triggered,
      &block : ::Proc(::Crysterm::Action::Event::Triggered, ::Nil)
    )
      on event, block
    end

    # def activate(event : ActionEvent = ActionEvent::Event::Triggered)
    def activate(event : Event::Triggered.class | Event::Hovered.class = Event::Triggered)
      emit event
    end
  end
end
