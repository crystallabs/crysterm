module Crysterm
  # Per-widget `#css_sub_elements` overrides: each widget that draws with named
  # sub-styles exposes them as pseudo-element nodes in the CSS document, so they
  # can be targeted by their capitalized name (e.g. `Table Cell { ... }`,
  # `ListBar Prefix { ... }`, `ProgressBar Bar { ... }`).
  #
  # The cascade already routes each slot into the matching `Style` sub-style
  # (see `Cascade#get_sub_style`); these overrides just make the nodes exist.
  # Each calls `super` so the base scrollbar/track slots (when scrolling is
  # enabled) are preserved.
  class Widget
    class List
      def css_sub_elements : Array(String)
        super + ["item"]
      end
    end

    class ListBar
      def css_sub_elements : Array(String)
        super + ["prefix", "bar"]
      end
    end

    class ListTable
      def css_sub_elements : Array(String)
        super + ["header", "cell", "alternate"]
      end
    end

    class Table
      def css_sub_elements : Array(String)
        super + ["header", "cell", "alternate"]
      end
    end

    class ProgressBar
      def css_sub_elements : Array(String)
        super + ["bar"]
      end
    end

    class Dial
      def css_sub_elements : Array(String)
        super + ["bar"]
      end
    end

    class Slider
      def css_sub_elements : Array(String)
        super + ["bar"]
      end
    end
  end
end
