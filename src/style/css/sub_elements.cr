module Crysterm
  # Per-widget `#css_sub_elements` overrides: each widget that draws with named
  # sub-styles exposes them as pseudo-element nodes in the CSS document, so they
  # can be targeted by their capitalized name (e.g. `Table Cell { ... }`,
  # `ListBar Prefix { ... }`, `ProgressBar Indicator { ... }`).
  #
  # The cascade routes each slot into the matching `Style` sub-style; these
  # overrides just make the nodes exist. Each calls `super` to preserve the base
  # scrollbar/track slots.
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
      # `indicator` is the submenu arrow (`Menu::indicator { glyph: "▶" }`);
      # the check-column marks of checkable rows follow the registry directly.
      def css_sub_elements : Array(String)
        super + ["separator", "indicator"]
      end
    end

    class TabWidget
      # `close-button` carries the closable-tab `✕` glyph
      # (`TabWidget::close-button { glyph: "x" }`).
      def css_sub_elements : Array(String)
        super + ["tab", "pane", "close-button"]
      end
    end

    # The checkable marker controls expose their `[x]`/`(*)` marker as the
    # `indicator` sub-control (Qt's `QCheckBox::indicator`), carrying the
    # `glyph`/`glyph-open`/`glyph-close` family; state pseudos address the
    # per-state mark (`CheckBox::indicator:checked { glyph: "x" }`, since the
    # `[checked]` attribute is emitted on the sub-element node too).
    class CheckBox
      def css_sub_elements : Array(String)
        super + ["indicator"]
      end
    end

    class RadioButton
      def css_sub_elements : Array(String)
        super + ["indicator"]
      end
    end

    # The drop-down affordances expose their arrow as the `drop-down`
    # sub-control (Qt's `QComboBox::drop-down`), e.g.
    # `ComboBox::drop-down { glyph: "▾" }`.
    class ComboBox
      def css_sub_elements : Array(String)
        super + ["drop-down"]
      end
    end

    class ToolButton
      def css_sub_elements : Array(String)
        super + ["drop-down"]
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
    # alternate slots.

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

    # A standalone `ScrollBar` is not itself `scrollable?`, so the base slots
    # don't surface; expose its own chrome instead: `track` (trough, Qt's
    # `::groove`), `indicator` (handle, Qt's `::handle`), and the `QScrollBar`
    # sub-controls — stepper buttons, arrow glyphs, and trough regions
    # before/after the handle.
    class ScrollBar
      def css_sub_elements : Array(String)
        super + ["track", "indicator",
                 "sub-line", "add-line", "sub-page", "add-page",
                 "up-arrow", "down-arrow", "left-arrow", "right-arrow"]
      end
    end
  end
end
