require "./label"
require "../subscription"

module Crysterm
  class Widget
    # A `Label` showing the caret's line and column of a text view (a
    # `PlainTextEdit`, `TextEdit` or `TextBrowser`) — the "Ln 1, Col 1"
    # field of an editor's status bar — kept up to date on the view's
    # `Event::CursorPositionChanged` and `Event::TextChanged` (an edit can
    # move the caret's line without moving the caret). Both numbers are
    # 1-based, the column counting characters from the line's start;
    # `#format` renders them, `"Ln #{line}, Col #{column}"` by default.
    #
    # ```
    # bar.add_permanent_widget Widget::CursorPositionLabel.new(editor, width: "15%")
    # ```
    #
    # `.text_for` gives the text alone, for a field an app composes itself.
    #
    # Excluded from the DOM-loader registry: needs the view it follows
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    class CursorPositionLabel < Label
      DEFAULT_FORMAT = ->(line : Int32, column : Int32) { "Ln #{line}, Col #{column}" }

      # The view followed.
      getter view : Mixin::TextEditing::DocumentBuffer

      # Renders the 1-based line and column.
      getter format : Proc(Int32, Int32, String)

      # The subscriptions on the view, ended with the label.
      @subs = Crysterm::Subscriptions.new

      def initialize(@view : Mixin::TextEditing::DocumentBuffer, format : Proc(Int32, Int32, String) = DEFAULT_FORMAT, **opts)
        @format = format
        super(**{content: CursorPositionLabel.text_for(@view, format)}.merge(opts))
        @subs.on(@view, Crysterm::Event::CursorPositionChanged) { refresh }
        @subs.on(@view, Crysterm::Event::TextChanged) { refresh }
      end

      def format=(format : Proc(Int32, Int32, String)) : Proc(Int32, Int32, String)
        @format = format
        refresh
        format
      end

      # Brings the text in line with the view's caret.
      def refresh : Nil
        self.text = CursorPositionLabel.text_for(@view, @format)
      end

      # The caret's line and column of *view*, rendered with *format*.
      def self.text_for(view : Mixin::TextEditing::DocumentBuffer, format : Proc(Int32, Int32, String) = DEFAULT_FORMAT) : String
        cursor = TextCursor.new(view.document, view.cursor_position)
        format.call(cursor.block_number + 1, cursor.column_number + 1)
      end

      def destroy
        @subs.off
        super
      end
    end

    # A `Label` showing where in its content a scrolling view is, the way
    # vi reports it at the right of its status line: `All` when the whole
    # content fits, else `Top`, `Bot`, or the percentage scrolled. Kept up
    # to date on the view's `Event::Scroll` and `Event::Resize`; `#refresh`
    # for a content change the app knows about.
    #
    # ```
    # bar.add_permanent_widget Widget::ScrollPositionLabel.new(viewer, width: 5)
    # ```
    #
    # `.text_for` gives the text alone.
    #
    # Excluded from the DOM-loader registry: needs the view it follows
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    class ScrollPositionLabel < Label
      # The view followed.
      getter view : Widget

      # The subscriptions on the view, ended with the label.
      @subs = Crysterm::Subscriptions.new

      def initialize(@view : Widget, **opts)
        super(**{content: ScrollPositionLabel.text_for(@view)}.merge(opts))
        @subs.on(@view, Crysterm::Event::Scroll) { refresh }
        @subs.on(@view, Crysterm::Event::Resize) { refresh }
      end

      # Brings the text in line with the view's scroll position.
      def refresh : Nil
        self.text = ScrollPositionLabel.text_for(@view)
      end

      # *view*'s reading position as vi reports it.
      def self.text_for(view : Widget) : String
        return "All" unless view.overflows_y?
        percent = view.scroll_percent
        if percent <= 0.0
          "Top"
        elsif percent >= 1.0
          "Bot"
        else
          "#{(percent * 100).round.to_i}%"
        end
      end

      def destroy
        @subs.off
        super
      end
    end
  end
end
