module Crysterm
  # Per-widget `#css_sub_elements` overrides: each widget that draws with named
  # sub-styles exposes them as pseudo-element nodes in the CSS document, so they
  # can be targeted by their capitalized name (e.g. `Table Cell { ... }`,
  # `ListBar Prefix { ... }`, `ProgressBar Indicator { ... }`).
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
        super + ["prefix"]
      end
    end

    class Menu
      def css_sub_elements : Array(String)
        super + ["separator"]
      end
    end

    class TabWidget
      def css_sub_elements : Array(String)
        super + ["tab", "pane"]
      end
    end

    class GroupBox
      def css_sub_elements : Array(String)
        super + ["title"]
      end
    end

    class DockWidget
      def css_sub_elements : Array(String)
        super + ["title", "close-button", "float-button"]
      end
    end

    # NOTE: `Table` and `ListTable` expose their cells as individual per-cell
    # nodes (`Cell`/`Header`/`Row`) instead of representative header/cell/
    # alternate slots — see `table_cells.cr`.

    class ProgressBar
      def css_sub_elements : Array(String)
        super + ["indicator"]
      end
    end

    class Dial
      def css_sub_elements : Array(String)
        super + ["indicator"]
      end
    end

    class Slider
      def css_sub_elements : Array(String)
        super + ["indicator"]
      end
    end
  end
end
