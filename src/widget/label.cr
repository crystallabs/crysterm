require "./box"

module Crysterm
  class Widget
    # Basic read-only label
    #
    # <!-- widget-examples:capture v1 -->
    # ![Label screenshot](../../tests/widget/label/label.5s.apng)
    # <!-- /widget-examples:capture -->
    class Label < Box
      @shrink_to_fit = true

      # Positional text convenience — Qt's `QLabel(text)`. Routed via
      # `content:`; an explicit `content:` in *opts* wins over the positional
      # *text*.
      #
      # `Label` has no `initialize` of its own otherwise (it fully inherits
      # `Widget`'s), so this overload is paired with the passthrough below —
      # defining just the one overload here would shadow every inherited
      # keyword-only overload.
      def initialize(text : String, **opts)
        super(**{content: text}.merge(opts))
      end

      # :nodoc:
      def initialize(parent = nil, **opts)
        super(parent, **opts)
      end

      # The label's text, modeled after Qt's `QLabel#text`.
      #
      # An alias for the raw `Widget#content`, so it round-trips: what `#text=`
      # stores is what `#text` gives back, tags and all. Rendering is governed
      # separately by `#wrap_content?` (Qt's `wordWrap`), `#parse_tags?` and
      # `#align`; for the post-parse, wrapped view see `Widget#rendered_text`.
      def text : String
        content
      end

      # :ditto:
      def text=(text : String)
        self.content = text
      end
    end

    alias Text = Label
  end
end
