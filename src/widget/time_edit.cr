require "./input"
require "../mixin/sectioned_field"

module Crysterm
  class Widget
    # Time entry field, modeled after Qt's `QTimeEdit`.
    #
    # Shows an `HH:MM:SS` time with one *section* highlighted. Click a section to
    # select it; Left/Right also move between the hour/minute/second sections;
    # Up/Down or the mouse wheel step the active one (each wraps within its range,
    # without carrying into the next). Emits `Event::DateChange` (carrying a
    # `Time`) whenever the time changes.
    #
    # Like Qt's `QTimeEdit`, it is edited in place (there is no drop-down) — so a
    # click selects the clicked section rather than opening a popup. The shared
    # section machinery lives in `Mixin::SectionedField`.
    #
    # The value is held as a `Time` so it composes with `DateEdit`/`Calendar`;
    # only its hour/minute/second are shown and edited.
    class TimeEdit < Input
      include Mixin::SectionedField

      @resizable = false

      @time : Time
      # `@section`: 0 = hour, 1 = minute, 2 = second (default hour, from the mixin).

      # Whether to show (and edit) the seconds section.
      property? show_seconds : Bool = true

      def initialize(time : Time? = nil, show_seconds = true, **input)
        @time = (time || (Time.local rescue Time.utc(2000, 1, 1)))
        @show_seconds = show_seconds

        super **input
        @parse_tags = true

        handle Crysterm::Event::KeyPress
        setup_section_mouse

        update_content
      end

      def time : Time
        @time
      end

      def time=(value : Time) : Time
        return @time if value == @time
        @time = value
        update_content
        emit Crysterm::Event::DateChange, @time
        request_render
        @time
      end

      private def section_count : Int32
        show_seconds? ? 3 : 2
      end

      # Maps an absolute x to a section index. Sections sit at `HH:MM:SS` columns
      # 0-1 / 3-4 / 6-7 (3 cells apart); `nil` when off the field.
      private def section_at(x : Int32) : Int32?
        col = x - aleft - ileft
        return nil if col < 0
        (col // 3).clamp(0, section_count - 1)
      rescue
        nil
      end

      private def update_content : Nil
        parts = [@time.hour.to_s.rjust(2, '0'), @time.minute.to_s.rjust(2, '0')]
        parts << @time.second.to_s.rjust(2, '0') if show_seconds?
        parts[@section] = "{inverse}#{parts[@section]}{/inverse}" if @section < parts.size
        set_content parts.join(':')
      end

      # Steps the active section by *delta*, wrapping within its own range.
      private def step(delta : Int32) : Nil
        h, m, sec = @time.hour, @time.minute, @time.second
        case @section
        when 0 then h = (h + delta) % 24
        when 1 then m = (m + delta) % 60
        else        sec = (sec + delta) % 60
        end
        h += 24 if h < 0
        m += 60 if m < 0
        sec += 60 if sec < 0
        self.time = Time.local(@time.year, @time.month, @time.day, h, m, sec)
      end

      def on_keypress(e)
        handle_section_key e
      end
    end
  end
end
