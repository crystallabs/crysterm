require "./scrollable_text"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Log screenshot](../../examples/widget/log/log-capture.png)
    # <!-- /widget-examples:capture -->
    class Log < ScrollableText
      # Severity of a log line, à la a typical logger / Qt logging categories.
      # Ordered from least to most severe so `#min_level` can filter.
      enum Level
        Debug
        Info
        Warn
        Error

        # Color (named) used to tag the `[LEVEL]` marker when the widget parses
        # tags.
        def color : String
          case self
          in Debug then "blue"
          in Info  then "green"
          in Warn  then "yellow"
          in Error then "red"
          end
        end

        # Marker shown before the message, e.g. `[WARN]`.
        def label : String
          "[#{to_s.upcase}]"
        end
      end

      # Lines below this severity are dropped by the level helpers
      # (`#debug`/`#info`/`#warn`/`#error`). Defaults to `Debug` (no filtering).
      property min_level : Level = Level::Debug

      # Whether the level helpers prefix each line with a timestamp.
      property? timestamps : Bool = false

      # `Time#to_s` format used when `#timestamps?`.
      property timestamp_format : String = "%H:%M:%S"

      # `scroll_percentage` must reflect/drive the real scroll position. It used
      # to be a plain `property` (inert Int), so `self.scroll_percentage = 100`
      # just stored 100 and never scrolled, and the `== 100` check below read a
      # stale constant. Delegate to the actual scroll-percentage methods.
      def scroll_percentage
        get_scroll_perc false
      end

      def scroll_percentage=(i)
        set_scroll_perc i
      end

      def initialize(
        @scroll_on_input = false,
        @scrollback = Int32::MAX,
        max_lines = nil,
        timestamps = false,
        min_level = Level::Debug,
        **scrollable_text,
      )
        super **scrollable_text

        @timestamps = timestamps
        @min_level = min_level
        # `max_lines` is the friendlier alias for `scrollback`.
        max_lines.try { |v| @scrollback = v }

        on Crysterm::Event::SetContent, ->set_content(Crysterm::Event::SetContent)
      end

      # Maximum number of retained lines, an alias for `#scrollback` (Qt's
      # `QPlainTextEdit#maximumBlockCount`).
      def max_lines : Int32
        @scrollback
      end

      # :ditto:
      def max_lines=(value : Int32)
        @scrollback = value
      end

      # Appends a line at *level*, honoring `#min_level`, an optional timestamp,
      # and a colored `[LEVEL]` marker (colored only when the widget parses
      # tags). The `#debug`/`#info`/`#warn`/`#error` helpers wrap this.
      def log(level : Level, *args)
        return if level < @min_level

        msg = args.map(&.to_s).join(" ")
        line = String.build do |s|
          if timestamps?
            s << Time.local.to_s(@timestamp_format) << ' '
          end
          if parse_tags?
            s << '{' << level.color << "-fg}" << level.label << "{/" << level.color << "-fg} "
          else
            s << level.label << ' '
          end
          s << msg
        end

        add line
      end

      def debug(*args)
        log Level::Debug, *args
      end

      def info(*args)
        log Level::Info, *args
      end

      def warn(*args)
        log Level::Warn, *args
      end

      def error(*args)
        log Level::Error, *args
      end

      def set_content(e)
        if !@_user_scrolled || @scroll_on_input
          self.scroll_percentage = 100
          @_user_scrolled = false
          request_render
        end
      end

      # Append a line to the log. Multiple arguments are stringified and joined
      # with a space (like `puts`), so `add "mouse", x` logs `mouse 5` — not the
      # `["mouse", 5]` that the old `args.inspect` produced. The new line scrolls
      # into view at the bottom (unless the user has scrolled up to read back),
      # and the oldest lines are dropped once `scrollback` is exceeded.
      def add(*args)
        text = args.map(&.to_s).join(" ")

        emit Crysterm::Event::Log, text

        ret = push_line text

        if @_clines.fake.size > @scrollback
          shift_line @scrollback // 3
        end

        ret
      end

      # Defaults mirror the base `scroll(offset = 1, always = false)` so a
      # one-arg `scroll 0` (from `scroll_to`/`set_scroll_perc`) dispatches here
      # instead of silently falling through to the base method.
      def scroll(offset = 1, always = false)
        if offset == 0
          return super offset, always
        end

        @_user_scrolled = true

        ret = super offset, always

        # `scroll_percentage` is a float; use `>= 100` rather than `== 100` so a
        # bottom position that computes to e.g. 99.999 still re-enables
        # auto-scroll instead of getting stuck with `@_user_scrolled` true.
        if scroll_percentage >= 100
          @_user_scrolled = false
        end

        ret
      end
    end
  end
end
