require "./scrollable_text"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Log screenshot](../../examples/widget/log/log-capture5s.apng)
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

        # A log follows the tail by default (Qt sticky-bottom): new lines scroll
        # into view unless the user has scrolled up to read back.
        @follow_tail = true

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

      # Re-render when content changes; the actual tail-following is now the
      # generic `#follow_tail` sticky-bottom (with `scroll_on_input` honored via
      # `#stick_to_tail?` below), rather than a bespoke `@_user_scrolled` flag.
      def set_content(e)
        request_render
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
          # Trim a chunk (a third of the limit) rather than one line at a time,
          # so a busy log doesn't shift on every append. `Math.max(1, …)` keeps
          # this making progress for a tiny `scrollback`: `scrollback // 3` is 0
          # for `max_lines` of 1 or 2, which would `shift_line 0` (a no-op) and
          # let the buffer grow without bound past the limit.
          shift_line Math.max(1, @scrollback // 3)
        end

        ret
      end

      # Sticky-bottom normally; `scroll_on_input` additionally jumps to the
      # bottom whenever new content arrives (`content_max` grew past the previous
      # extent), even after a manual scroll-up.
      protected def stick_to_tail?(content_max : Int32) : Bool
        super || (@scroll_on_input && content_max > @last_scroll_max)
      end
    end
  end
end
