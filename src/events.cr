require "event_handler"

module Crysterm
  include EventHandler

  event DataEvent, data : String
  event WarningEvent, message : String

  # Emitted when screen is resized.
  event ResizeEvent

  event HideEvent
  event ShowEvent

  # Emitted when element focuses. Requires terminal supporting the focus protocol.
  event FocusEvent, el : Element? = nil

  # Emitted when element goes out of focus. Requires terminal supporting the focus protocol.
  event BlurEvent, el : Element? = nil

  # Emitted when a `Screen` is destroyed. Probably only useful when using multiple screens.
  event DestroyEvent

  # Emitted at the beginning of rendering/drawing.
  event PreRenderEvent

  # Emitter at the end or rendering/drawing.
  event RenderEvent

  # event PostRenderEvent

  # Emitted at the end of drawing. Currently disabled/unused.
  # event DrawEvent

  event SetContentEvent
  event ParsedContentEvent

  # Emitted when node gains a new parent
  event ReparentEvent, element : Node?

  # Emitted when node is added to parent
  event AdoptEvent, element : Element

  # Emitted when node is removed from its current parent
  event RemoveEvent, node : Node

  # Emitted when node is attached to a screen directly or somewhere in its ancestry
  event AttachEvent

  # Emitted when node is detached from a screen directly or somewhere in its ancestry
  event DetachEvent

  event KeyEvent, key : Tput::Key

  class KeyPressEvent < EventHandler::Event
    property char : Char
    property key : Tput::Key?
    property sequence : Array(Char)
    property? accepted : Bool = false

    def initialize(char, @key = nil, @sequence = [char])
      @char = char
    end

    def accept!
      @accepted = true
    end

    def ignore!
      @accepted = false
    end
  end

  # event KeyPressEvent, ch : Char, key : Key
  event ClickEvent

  event PressEvent

  event CheckEvent, value : Bool
  event UnCheckEvent, value : Bool

  event MoveEvent

  event CompleteEvent

  event SubmitEvent, value : String
  event CancelEvent, value : String
  event ActionEvent, value : String

end
