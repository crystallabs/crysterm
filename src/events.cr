require "event_handler"

module Crysterm
    include EventHandler

    event DataEvent, data : String
    event WarningEvent, message : String

    event ResizeEvent
    event AttachEvent
    event DetachEvent

    event HideEvent
    event ShowEvent

    event BlurEvent
    event FocusEvent
    event DestroyEvent

    event RenderEvent
    event PreRenderEvent
    event PostRenderEvent
    event DrawEvent

    event SetContentEvent
    event ParsedContentEvent

    event ReparentEvent, element : Node?
    event AdoptEvent, element : Element
    event RemoveEvent, node : Node

    event KeyEvent, key : Tput::Key

    class KeyPressEvent < EventHandler::Event
      property char : Char
      property key : Tput::Key?
      property sequence : Array(Char)
      property? accepted : Bool = false
      def initialize(@char, @key=nil, @sequence=[@char])
      end
      def accept!
        @accepted = true
      end
      def ignore!
        @accepted = false
      end
    end

    #event KeyPressEvent, ch : Char, key : Key
    event ClickEvent

    event PressEvent

    event CheckEvent
    event UnCheckEvent

    event MoveEvent
end
