require "./box"

module Crysterm
  class Widget
    # Horizontal status bar, modeled after Qt's `QStatusBar`.
    #
    # Shows a temporary `#message` on the left (set with `#show_message`,
    # optionally auto-clearing after a timeout) and any number of *permanent*
    # sections right-aligned (added with `#add_permanent`). Typically one row tall
    # at the bottom of a window.
    #
    # ```
    # bar = Widget::StatusBar.new parent: window, bottom: 0, left: 0, width: "100%", height: 1
    # bar.add_permanent "UTF-8"
    # bar.add_permanent "Ln 1, Col 1"
    # bar.show_message "Saved", 2.seconds
    # ```
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    # <!-- widget-examples:capture v1 -->
    # ![StatusBar screenshot](../../tests/widget/status_bar/status_bar.5s.apng)
    # <!-- /widget-examples:capture -->
    class StatusBar < Box
      # Generation-guarded timed dismissal: a pending `#show_message` timeout only
      # clears *its own* message, not a newer one.
      include ::Crysterm::Mixin::TimedDismissal

      # The current temporary (left-aligned) message.
      getter message : String = ""

      # Permanent (right-aligned) sections, in insertion order; the first added
      # sits left-most of the right group (Qt's `addPermanentWidget` order).
      @permanent = [] of String

      # A snapshot of the permanent sections' texts. A copy, not the live array:
      # the render string is cached against the sections, so mutating them
      # behind the bar's back would paint stale text. Add and remove through
      # `#add_permanent`/`#clear_permanent`, and rewrite one through its
      # `Section` handle — all of which keep the cache honest.
      def permanent : Array(String)
        @permanent.dup
      end

      # Cached joined render string for `#permanent`, rebuilt only when the
      # sections change.
      @permanent_text = ""

      # Cached left-truncated permanent string plus the `(avail, source)` it was
      # built for, so a steady-state overflowing status bar doesn't slice a fresh
      # substring every frame.
      @_trunc : String = ""
      @_trunc_key : Tuple(Int32, String)?

      # `style_to_attr` memo for the per-frame permanent-section overlay: the
      # bar redraws every render with an unchanged style, so the attr
      # derivation is skipped until a style setter (or a cascade swap)
      # invalidates it.
      @attr_memo = Style::AttrMemo.new

      def initialize(**box)
        super **box
        # Keyboard-reachable chrome, like `MenuBar`/`ToolBar` — but the bar
        # itself takes no keys, so the F6/Shift+F6 region cycle (see
        # `window_region_focus.cr`) only actually stops here once the bar hosts
        # a focusable child widget. Turn off via `region_focusable = false`.
        @region_focusable = true
      end

      # Shows *text* as the temporary message. With *timeout*, the message clears
      # itself after that span (unless replaced first); without, it stays until
      # the next `#show_message`/`#clear_message`.
      def show_message(text : String, timeout : Time::Span? = nil) : Nil
        @message = text
        gen = bump_dismiss_gen
        update!

        if timeout
          after timeout do
            # Marshal back onto the render fiber; only clear if still current.
            window?.try &.post do
              if dismiss_current?(gen)
                @message = ""
                update!
              end
            end
          end
        end
      end

      # Clears the temporary message immediately (Qt's `clearMessage`).
      def clear_message : Nil
        @message = ""
        bump_dismiss_gen
        update!
      end

      # :ditto: assignment form.
      def message=(text : String) : String
        show_message text
        text
      end

      # One permanent (right-aligned) section of a `StatusBar` — the handle
      # `#add_permanent` returns, through which the section's text is read and
      # rewritten in place:
      #
      # ```
      # pos = bar.add_permanent "Ln 1, Col 1"
      # pos.text = "Ln 4, Col 12"
      # ```
      #
      # A handle is a *view*: it holds a position, not a copy, so it goes stale if
      # sections are removed around it — take a fresh one from
      # `#permanent_sections`.
      struct Section
        # The owning bar and this section's position in it.
        getter owner : StatusBar
        getter index : Int32

        def initialize(@owner, @index)
        end

        # This section's text.
        def text : String
          @owner.permanent_at(@index) || ""
        end

        # Replaces this section's text — the idiom for live sections like a
        # `Ln, Col` readout. A no-op when the text is unchanged (or the handle
        # is stale).
        def text=(value : String) : String
          @owner.rewrite_permanent @index, value
          value
        end
      end

      # Appends a permanent right-aligned section (Qt's `addPermanentWidget`,
      # specialized to a text label) and returns its `Section` handle, through
      # which it can be updated in place.
      def add_permanent(text : String) : Section
        @permanent << text
        rebuild_permanent
        Section.new self, @permanent.size - 1
      end

      # Handles for every permanent section, in order — the item-object face of
      # the bar (`bar.permanent_sections[0].text = "…"`).
      def permanent_sections : Array(Section)
        Array(Section).new(@permanent.size) { |i| Section.new(self, i) }
      end

      # The live text at *index*, for `Section#text`.
      protected def permanent_at(index : Int32) : String?
        return unless index >= 0
        @permanent[index]?
      end

      # Rewrites the section at *index*; out of range (or unchanged) is a no-op.
      # Reached through `Section#text=`, which is the public spelling.
      protected def rewrite_permanent(index : Int32, text : String) : Nil
        return unless 0 <= index < @permanent.size
        return if @permanent[index] == text
        @permanent[index] = text
        rebuild_permanent
      end

      # Removes the first permanent section equal to *text* (Qt's
      # `removeWidget`, specialized to a text label); a no-op when none matches.
      def remove_permanent(text : String) : Nil
        idx = @permanent.index text
        return unless idx
        @permanent.delete_at idx
        rebuild_permanent
      end

      # Removes all permanent sections.
      def clear_permanent : Nil
        @permanent.clear
        rebuild_permanent
      end

      # Rebuilds the cached joined render string after any section change.
      private def rebuild_permanent : Nil
        @permanent_text = @permanent.join " #{glyph(Glyphs::Role::LineVertical)} "
        update!
      end

      def paint(*, with_children = true)
        set_content @message
        super
        draw_permanent
      end

      # Overlays the permanent sections, right-aligned, after the base render
      # paints the background and (left) message. Uses freshly resolved
      # interior coordinates, so it never lags a frame behind a resize.
      private def draw_permanent : Nil
        return if @permanent.empty?
        with_inner_coords do |xi, xl, yi, _yl|
          avail = xl - xi
          return if avail <= 0
          text = @permanent_text
          # Right-aligned: on overflow drop the *left* end so the tail (the most
          # recently added sections) stays visible. The sliced tail is cached
          # against `(avail, source)` so an overflowing bar doesn't re-slice each
          # frame. All accounting is in display cells (`str_width`), not
          # codepoints, or wide (CJK/emoji) sections misplace the run.
          tw = str_width text
          if tw > avail
            key = {avail, text}
            if @_trunc_key != key
              @_trunc_key = key
              # `tail_within` (the toolkit-wide helper): longest suffix fitting
              # `avail` cells, never splitting a grapheme.
              @_trunc = tail_within text, avail
            end
            text = @_trunc
            tw = str_width text
          end
          draw_text_run yi, xl - tw, text, xl, @attr_memo.fetch(style)
        end
      end
    end
  end
end
