require "./scrollable_text"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Log screenshot](../../tests/widget/log/log.5s.apng)
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

      # Maximum number of retained lines (Qt's `QPlainTextEdit#maximumBlockCount`);
      # oldest lines are dropped once exceeded.
      property max_lines : Int32 = Int32::MAX

      def initialize(
        @scroll_on_input = false,
        @max_lines = Int32::MAX,
        timestamps = false,
        min_level = Level::Debug,
        **scrollable_text,
      )
        super **scrollable_text

        @timestamps = timestamps
        @min_level = min_level

        # Sticky-bottom by default: new lines scroll into view unless the user
        # has scrolled up.
        @follow_tail = true

        on Crysterm::Event::ContentChanged, ->on_set_content(Crysterm::Event::ContentChanged)
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

      def on_set_content(e)
        request_render
      end

      # Append a line to the log. Arguments are stringified and joined with a
      # space (like `puts`), so `add "mouse", x` logs `mouse 5`. Oldest lines
      # are dropped once `max_lines` is exceeded.
      def add(*args)
        text = args.map(&.to_s).join(" ")

        emit Crysterm::Event::Log, text

        ret = append_line text

        if @_clines.fake.size > @max_lines
          # Trim a third of the limit at once rather than one line per append.
          # `Math.max(1, …)` avoids a no-op `remove_first_line 0` when `max_lines` < 3.
          remove_first_line Math.max(1, @max_lines // 3)
        end

        ret
      end

      # Sticky-bottom normally; `scroll_on_input` also jumps to the bottom
      # whenever new content arrives, even after a manual scroll-up.
      protected def stick_to_tail?(content_max : Int32) : Bool
        super || (@scroll_on_input && content_max > @last_scroll_max)
      end
    end
  end
end
