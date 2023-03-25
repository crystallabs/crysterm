require "event_handler"
require "tput"

module Crysterm
  # Collection of all events used by Crysterm
  module Event
    include EventHandler

    # Events currently unused have been commented. Uncomment on first use.

    # Emitted when widget is attached to a screen directly or somewhere in its ancestry
    event Attach, object : EventHandler

    # Emitted when widget is detached from a screen directly or somewhere in its ancestry
    event Detach, object : EventHandler

    # Emitted when widget gains a new parent
    event Reparent, widget : Widget?

    # Emitted when widget is added to parent
    event Adopt, widget : Widget

    # Emitted when widget is removed from its current parent
    event Remove, widget : Widget

    # Emitted when Widget is destroyed
    event Destroy

    # Emitted when widget focuses. Requires terminal supporting the focus protocol.
    event Focus, el : Widget? = nil

    # Emitted when widget goes out of focus. Requires terminal supporting the focus protocol.
    event Blur, el : Widget? = nil

    # Emitted when widget scrolls
    event Scroll

    # # Emitted on some data
    # event Data, data : String

    # # Emitted on a warning event
    # event Warning, message : String

    # Emitted when screen is resized.
    event Resize, size : Tput::Namespace::Size? = nil

    # Emitted when object is hidden
    event Hide

    # Emitted when object is shown
    event Show

    # Emitted at the beginning of rendering/drawing.
    event PreRender

    # Emitter at the end or rendering/drawing.
    event Rendered

    # # event PostRender

    # # Emitted at the end of drawing. Currently disabled/unused.
    # # event Draw

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

    # # Emitted on something being reset (e.g. progressbar reset to 0%)
    # event Reset

    # Emitted on value submitted (e.g. in text forms)
    event Submit, value : String

    # Emitted on value canceled (e.g. in text forms)
    event Cancel, value : String

    event Action, value : String

    # Emitted on creation of a list item
    event CreateItem

    # Emitted on addition of a list item to list
    event AddItem
    # Emitted on removal of a list item
    event RemoveItem
    # Emitted on re-set/re-definition of list items
    event SetItem
    # :ditto:
    event SetItems

    event CancelItem, item : Widget::Box, index : Int32
    event ActionItem, item : Widget::Box, index : Int32

    # # Event emitted when a new log line intended for `Widget::LogLine` is issued
    # event LogLine, text : String
    # # NOTE In Blessed, this is called `log` and `Widget::Log`. It's been renamed
    # # in Crysterm not to conflict with `Log` coming from logger.

    # Emitted on selection of an item in list
    event SelectItem, item : Widget::Box, index : Int32

    # Emitted when an Action is Triggered
    event Triggered

    # Emitted when a Widget or Action are hovered
    event Hovered

    # # event Key, key : ::Tput::Key

    # Individual key events emitted on specific key presses. This is used when
    # the caller does not want to listen for everything on `Event::KeyPress` (i.e.
    # all keypresses), but when they want explicit keys like
    # `Event::KeyPress::CtrlQ`.
    class KeyPress < EventHandler::Event
      property char : Char
      property key : ::Tput::Key?
      property sequence : Array(Char)
      property? accepted : Bool = false

      def initialize(char, @key = nil, @sequence = [char])
        @char = char
      end

      # Accepts event and causes it to stop propagating.
      def accept
        @accepted = true
      end

      # Ignores event and causes it to continue propagating.
      def ignore
        @accepted = false
      end

      # This macro takes all enum members from Tput::Key
      # and creates a `KeyPress::<member>` event for them,
      # such as `Event::KeyPress::CtrlQ`.
      #
      # This is done as a convenience, so that users would
      # not have to listen for all keypresses and then
      # manually check for particular keys every time.
      KEYS = {} of ::Tput::Key => self.class
      {% for m in ::Tput::Key.constants %}
        class {{m.id}} < self; end
        KEYS[ ::Tput::Key::{{m.id}} ] = {{m.id}}
      {% end %}
    end
  end
end
