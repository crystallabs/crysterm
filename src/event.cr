require "event_handler"
require "tput"

module Crysterm
  # Collection of all events used by Crysterm.
  module Event

    include EventHandler

    event Scroll

    event Data, data : String

    event Warning, message : String

    # Emitted when window is resized.
    event Resize

    event Hide
    event Show

    # Emitted at the beginning of rendering/drawing.
    event PreRender

    # Emitter at the end or rendering/drawing.
    event Render

    # event PostRender

    # Emitted at the end of drawing. Currently disabled/unused.
    # event Draw

    event SetContent
    event ParsedContent

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

    event Key, key : ::Tput::Key

    class KeyPress < EventHandler::Event
      property char : Char
      property key : ::Tput::Key?
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

      Key_events = {} of ::Tput::Key => self.class

      # This macro takes all enum members from Tput::Key
      # and creates a KeyPress::<member> event for them.
      {% for m in ::Tput::Key.constants %}
        class {{m.id}} < self; end
        Key_events[ ::Tput::Key::{{m.id}} ] = {{m.id}}
      {% end %}
    end
  end
end
