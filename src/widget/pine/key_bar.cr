module Crysterm
  class Widget
    module Pine
      # Shared building blocks for Pine's single-key command bars: the item
      # record, the highlighted-key tag lookup, and the content builder. Layout
      # and click handling stay in each bar widget.
      module KeyBar
        # A single key-triggered item: a `key` to press (shown highlighted), a
        # `label`, and an optional `callback`.
        class Item
          # The keyboard key that triggers this item (shown highlighted).
          property key : String

          # Human-readable description shown next to the key.
          property label : String

          # Optional action invoked when this item is triggered.
          property callback : Proc(Nil)?

          def initialize(@key, @label, @callback = nil)
          end
        end

        # Builds the tagged content for a single item: a highlighted key
        # followed by its label, e.g. `{reverse} ? {/reverse} Help`.
        private def format_entry(entry : Item) : String
          tags = key_tags
          "#{tags[:open]} #{entry.key} #{tags[:close]} #{entry.label}"
        end

        # Translates `key_style` into open/close tags used around the key.
        private def key_tags
          if @key_style.reverse?
            {open: "{reverse}", close: "{/reverse}"}
          elsif (fg = @key_style.fg) && fg >= 0
            hex = "#%06x" % (fg & 0xffffff)
            {open: "{#{hex}-fg}", close: "{/#{hex}-fg}"}
          else
            {open: "{bold}", close: "{/bold}"}
          end
        end
      end
    end
  end
end
