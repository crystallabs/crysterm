require "event_handler"
require "tput"

module Crysterm
  # Collection of all events used by Crysterm
  module Event
    include EventHandler

    # Emitted when element is attached to a screen directly or somewhere in its ancestry
    event Attach

    # Emitted when element is detached from a screen directly or somewhere in its ancestry
    event Detach

    # Emitted when element gains a new parent
    event Reparent, element : Widget?

    # Emitted when element is added to parent
    event Adopt, element : Widget

    # Emitted when element is removed from its current parent
    event Remove, element : Widget

    # Emitted when Widget is destroyed
    event Destroy

    # Emitted when element focuses. Requires terminal supporting the focus protocol.
    event Focus, el : Widget? = nil

    # Emitted when element goes out of focus. Requires terminal supporting the focus protocol.
    event Blur, el : Widget? = nil

    # Emitted when widget scrolls
    event Scroll

    # Emitted on some data
    event Data, data : String

    # Emitted on a warning event
    event Warning, message : String

    # Emitted when screen is resized.
    event Resize

    # Emitted when object is hidden
    event Hide

    # Emitted when object is shown
    event Show

    # Emitted at the beginning of rendering/drawing.
    event PreRender

    # Emitter at the end or rendering/drawing.
    event Render

    # event PostRender

    # Emitted at the end of drawing. Currently disabled/unused.
    # event Draw

    # Emitted after Widget's content is defined
    event SetContent

    # Emitted after Widget's content is parsed
    event ParsedContent

    # Emitted on mouse click
    event Click

    # Emitted on button press
    event Press

    # Emitted on checkbox checked
    event Check, value : Bool

    # Emitted on checkbox unchecked
    event UnCheck, value : Bool

    # Emitted when Widget's position is changed
    event Move

    # Emitted on something being completed (e.g. progressbar reaching 100%)
    event Complete

    # Emitted on something being reset (e.g. progressbar reset to 0%)
    event Reset

    # Emitted on value submitted (e.g. in text forms)
    event Submit, value : String

    # Emitted on value canceled (e.g. in text forms)
    event Cancel, value : String

    event Action, value : String

    #event Key, key : ::Tput::Key

    # Emitted on key pressed
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

      KEYS = {} of ::Tput::Key => self.class

      # This macro takes all enum members from Tput::Key
      # and creates a KeyPress::<member> event for them.
      {% for m in ::Tput::Key.constants %}
        class {{m.id}} < self; end
        KEYS[ ::Tput::Key::{{m.id}} ] = {{m.id}}
      {% end %}
    end
  end
end
