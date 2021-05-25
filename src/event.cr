require "event_handler"

module Crysterm
  # Collection of all events used by Crysterm.
  module Event
    include EventHandler

    event Scroll

    event Data, data : String
    event Warning, message : String

    # Emitted when screen is resized.
    event Resize

    event Hide
    event Show

    # Emitted when element focuses. Requires terminal supporting the focus protocol.
    event Focus, el : Widget::Element? = nil

    # Emitted when element goes out of focus. Requires terminal supporting the focus protocol.
    event Blur, el : Widget::Element? = nil

    # Emitted when a `Screen` is destroyed. Probably only useful when using multiple screens.
    event Destroy

    # Emitted at the beginning of rendering/drawing.
    event PreRender

    # Emitter at the end or rendering/drawing.
    event Render

    # event PostRender

    # Emitted at the end of drawing. Currently disabled/unused.
    # event Draw

    event SetContent
    event ParsedContent

    # Emitted when node gains a new parent
    event Reparent, element : Node?

    # Emitted when node is added to parent
    event Adopt, element : Widget::Element

    # Emitted when node is removed from its current parent
    event Remove, node : Node

    # Emitted when node is attached to a screen directly or somewhere in its ancestry
    event Attach

    # Emitted when node is detached from a screen directly or somewhere in its ancestry
    event Detach

    event Key, key : Tput::Key

    class KeyPress < EventHandler::Event
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

      # This macro takes all enum members from Tput::Key
      # and creates a KeyPress::<member> event for them.
      {% for m in Tput::Key.constants %}
        class {{m.id}} < KeyPress; end
        App.key_events[ Tput::Key::{{m.id}} ] = {{m.id}}
      {% end %}
    end

    event Click

    event Press

    event Check, value : Bool
    event UnCheck, value : Bool

    event Move

    event Complete
    event Reset

    event Submit, value : String
    event Cancel, value : String
    event Action, value : String
  end
end
