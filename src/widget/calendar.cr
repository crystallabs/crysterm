require "./box"
require "./menu"
require "../mixin/sectioned_field"

module Crysterm
  class Widget
    # Month calendar, modeled after Qt's `QCalendarWidget`.
    #
    # Displays one month at a time as a grid of day cells, with a navigation bar
    # for moving between months and years and an optional weekday / week-number
    # header. The *shown page* (`#month_shown`/`#year_shown`) is tracked
    # separately from the *selected date* (`#selected_date`), as in Qt: the
    # navigation bar pages through months/years without changing the selection,
    # while moving the selection with the keyboard pages along with it.
    #
    # ### Selecting a day, month and year
    #
    # * **Day** — click a cell, or move the selection with the arrow keys
    #   (Left/Right by a day, Up/Down by a week) and press Enter.
    # * **Month** — click `‹`/`›` in the navigation bar, click the month name for
    #   a pop-up menu of all twelve months, wheel over the month name, or press
    #   Page Up/Page Down.
    # * **Year** — click the year for a pop-up menu of nearby years, or wheel
    #   over it.
    #
    # Home/End jump the selection to the first/last day of the shown month.
    #
    # ### Qt-modeled options
    #
    # * `#selection_mode` — `SingleSelection` (default) or `NoSelection`.
    # * `#navigation_bar_visible?` — show/hide the top navigation bar.
    # * `#horizontal_header_format` — weekday header: none, single-letter, or
    #   short names.
    # * `#vertical_header_format` — left column: none, or ISO week numbers.
    # * `#first_day_of_week` — which weekday starts each row.
    # * `#grid_visible?` — draw light separators between day columns.
    # * `#highlight_today?` — underline today's date.
    # * `#minimum_date` / `#maximum_date` (`#set_date_range`) — selectable range.
    #
    # Emits `Event::DateChange` when the selected date changes,
    # `Event::CurrentPageChange` when the shown month/year changes, and
    # `Event::Action` when a day is activated (Enter or click).
    #
    # ```
    # cal = Widget::Calendar.new parent: window, top: 0, left: 0, width: 22, height: 10,
    #   style: Style.new(border: true)
    # cal.on(Event::DateChange) { |e| status.content = e.date.to_s("%Y-%m-%d") }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Calendar screenshot](../../tests/widget/calendar/calendar.5s.apng)
    # <!-- /widget-examples:capture -->
    class Calendar < Box
      # Day-of-week selection behavior (Qt's `QCalendarWidget::SelectionMode`).
      enum SelectionMode
        # Days cannot be selected; the calendar is display-only.
        NoSelection
        # A single day is selected at a time (the default).
        SingleSelection
      end

      # Weekday header style (Qt's `QCalendarWidget::HorizontalHeaderFormat`).
      enum HorizontalHeaderFormat
        # No weekday header row.
        NoHeader
        # One letter per day (`S M T W T F S`).
        SingleLetterDayNames
        # Two-letter abbreviations (`Su Mo Tu …`).
        ShortDayNames
        # Long day names; rendered like `ShortDayNames` in the compact grid.
        LongDayNames
      end

      # Left-column header style (Qt's `QCalendarWidget::VerticalHeaderFormat`).
      enum VerticalHeaderFormat
        # No left column.
        NoHeader
        # ISO 8601 week numbers.
        ISOWeekNumbers
      end

      # Sunday-first two-letter and single-letter weekday labels; rotated to the
      # configured `#first_day_of_week` when rendered.
      WEEKDAYS_SHORT  = %w[Su Mo Tu We Th Fr Sa]
      WEEKDAYS_SINGLE = %w[S M T W T F S]
      MONTHS          = %w[January February March April May June July August September October November December]
      # Right-justified two-column day labels `" 1".." 31"`, indexed by `day - 1`,
      # so `#render_day` reuses a shared String instead of `d.to_s.rjust 2` per cell.
      DAY_CELLS = Array(String).new(31) { |i| (i + 1).to_s.rjust(2) }
      # Fixed to the longest month name ("September") so shorter names are
      # padded/centered and the year/steppers keep a stable column.
      MONTH_FIELD_WIDTH = MONTHS.max_of &.size

      # Marks the calendar keyable so the window routes key events to it when
      # focused (e.g. as a `DateEdit` popup, or via Tab).
      @keys = true

      # Selected date (at the beginning of its day).
      @date : Time

      # The month/year page currently on window, tracked separately from the
      # selection so the navigation bar can page without moving the selection.
      @shown_year : Int32
      @shown_month : Int32

      # Cached navigation-bar hit-test regions (content-relative columns),
      # recomputed by `#build_content`.
      @nav_prev_col = 0
      @nav_next_col = 0
      @nav_month_range = (0...0)
      @nav_year_range = (0...0)
      # Content rows above the day grid (nav bar + weekday header), and the
      # left column offset taken by the week-number gutter.
      @grid_top_row = 0
      @col_offset = 0

      # Month/year pop-up menus, lazily created and reused. Exposed read-only
      # so callers/tests can inspect the open dropdown.
      getter month_menu : Menu?
      getter year_menu : Menu?

      # Builds a `Time` for the given calendar date, falling back to UTC when
      # `Time.local` is unavailable (see `Mixin::SectionedField.default_today`).
      # Routing every constructed date through here keeps render/setter/constructor
      # paths from raising in headless contexts, which would otherwise defeat the
      # `default_today` fallback.
      private def local_date(year : Int32, month : Int32, day : Int32) : Time
        Time.local(year, month, day)
      rescue
        Time.utc(year, month, day)
      end

      # Getter plus setter that repaints only on an actual change.
      private macro visual(name, type, default)
        @{{name}} : {{type}} = {{default}}

        def {{name}} : {{type}}
          @{{name}}
        end

        def {{name}}=(value : {{type}}) : {{type}}
          return value if value == @{{name}}
          @{{name}} = value
          update_content
          request_render
          value
        end
      end

      visual selection_mode, SelectionMode, SelectionMode::SingleSelection
      visual horizontal_header_format, HorizontalHeaderFormat, HorizontalHeaderFormat::ShortDayNames
      visual vertical_header_format, VerticalHeaderFormat, VerticalHeaderFormat::NoHeader
      visual first_day_of_week, ::Time::DayOfWeek, ::Time::DayOfWeek::Sunday
      visual grid_visible, Bool, false
      visual navigation_bar_visible, Bool, true
      visual highlight_today, Bool, true

      # Bool predicates (Qt names these `gridVisible()`, etc.).
      def grid_visible? : Bool
        @grid_visible
      end

      def navigation_bar_visible? : Bool
        @navigation_bar_visible
      end

      def highlight_today? : Bool
        @highlight_today
      end

      # Earliest/latest selectable dates (Qt's `minimumDate`/`maximumDate`),
      # defaulting to Qt's own range.
      @minimum_date : Time = Time.utc(1752, 9, 14)
      @maximum_date : Time = Time.utc(9999, 12, 31)

      def minimum_date : Time
        @minimum_date
      end

      def minimum_date=(value : Time) : Time
        set_date_range value, @maximum_date
        @minimum_date
      end

      def maximum_date : Time
        @maximum_date
      end

      def maximum_date=(value : Time) : Time
        set_date_range @minimum_date, value
        @maximum_date
      end

      # Sets both bounds at once (Qt's `setDateRange`), re-clamping selection
      # and shown page into the new range.
      def set_date_range(min : Time, max : Time) : Nil
        min = min.at_beginning_of_day
        max = max.at_beginning_of_day
        min, max = max, min if min > max
        @minimum_date = min
        @maximum_date = max
        self.selected_date = clamp_date(@date)
        set_current_page @shown_year, @shown_month
        update_content
        request_render
      end

      def initialize(date : Time? = nil, mouse = true, **box)
        @date = clamp_date(date || Mixin::SectionedField.default_today)
        @shown_year = @date.year
        @shown_month = @date.month

        super **box
        @parse_tags = true

        handle Crysterm::Event::KeyPress
        setup_mouse if mouse

        update_content
      end

      # ── Selected date ─────────────────────────────────────────────────────

      # The selected date (Qt's `selectedDate`).
      def selected_date : Time
        @date
      end

      # Sets the selected date, clamped to `[minimum_date, maximum_date]`, paging
      # the view to show it and emitting `Event::DateChange` on an actual change.
      def selected_date=(value : Time) : Time
        v = clamp_date value
        return @date if v == @date
        @date = v
        show_selected_date
        update_content
        emit Crysterm::Event::DateChange, @date
        request_render
        @date
      end

      # `#selected_date` under its shorter, pre-existing name.
      def date : Time
        @date
      end

      # :ditto:
      def date=(value : Time) : Time
        self.selected_date = value
      end

      # ── Page navigation (Qt's setCurrentPage / show* family) ──────────────

      # The month (1-12) currently displayed.
      def month_shown : Int32
        @shown_month
      end

      # The year currently displayed.
      def year_shown : Int32
        @shown_year
      end

      # Shows the page for *year*/*month* (clamped to the date range) without
      # changing the selection, emitting `Event::CurrentPageChange` on a change.
      def set_current_page(year : Int32, month : Int32) : Nil
        idx = clamp_page(year * 12 + (month - 1))
        y = idx // 12
        m = idx % 12 + 1
        return if y == @shown_year && m == @shown_month
        @shown_year = y
        @shown_month = m
        update_content
        emit Crysterm::Event::CurrentPageChange, y, m
        request_render
      end

      def show_next_month : Nil
        shift_page_month 1
      end

      def show_previous_month : Nil
        shift_page_month -1
      end

      def show_next_year : Nil
        set_current_page @shown_year + 1, @shown_month
      end

      def show_previous_year : Nil
        set_current_page @shown_year - 1, @shown_month
      end

      # Pages to the month containing today.
      def show_today : Nil
        t = Mixin::SectionedField.default_today
        set_current_page t.year, t.month
      end

      # Pages to the month containing the selected date.
      def show_selected_date : Nil
        set_current_page @date.year, @date.month
      end

      private def shift_page_month(n : Int32) : Nil
        total = @shown_year * 12 + (@shown_month - 1) + n
        set_current_page total // 12, total % 12 + 1
      end

      # ── Range helpers ─────────────────────────────────────────────────────

      private def clamp_date(t : Time) : Time
        t = t.at_beginning_of_day
        return @minimum_date if t < @minimum_date
        return @maximum_date if t > @maximum_date
        t
      end

      private def min_page : Int32
        @minimum_date.year * 12 + (@minimum_date.month - 1)
      end

      private def max_page : Int32
        @maximum_date.year * 12 + (@maximum_date.month - 1)
      end

      private def clamp_page(idx : Int32) : Int32
        idx.clamp(min_page, max_page)
      end

      # ── Selection movement (keyboard) ─────────────────────────────────────

      private def shift_selection_days(n : Int32) : Nil
        self.selected_date = @date + n.days
      end

      private def shift_selection_months(n : Int32) : Nil
        total = @date.year * 12 + (@date.month - 1) + n
        y = total // 12
        m = total % 12 + 1
        d = Math.min(@date.day, Time.days_in_month(y, m))
        self.selected_date = local_date(y, m, d)
      end

      # ── Rendering ─────────────────────────────────────────────────────────

      # Column (0..6) of *t* relative to `#first_day_of_week`.
      private def column_of(t : Time) : Int32
        first = first_day_of_week.value % 7
        (t.day_of_week.value % 7 - first + 7) % 7
      end

      # Weekday labels for the header, rotated to `#first_day_of_week`.
      private def weekday_labels : Array(String)
        base = horizontal_header_format.single_letter_day_names? ? WEEKDAYS_SINGLE : WEEKDAYS_SHORT
        base.rotate(first_day_of_week.value % 7)
      end

      # Cached joined weekday header row (rotated labels padded and joined with
      # *sep*), rebuilt only when the header format, first day of week, or grid
      # visibility changes — not per keypress/render.
      @header_key : Tuple(HorizontalHeaderFormat, ::Time::DayOfWeek, Bool)?
      @header_str = ""

      private def weekday_header(sep : Char) : String
        key = {horizontal_header_format, first_day_of_week, grid_visible?}
        if @header_key != key
          @header_key = key
          @header_str = weekday_labels.map(&.rjust(2)).join(sep)
        end
        @header_str
      end

      private def update_content : Nil
        set_content build_content
      end

      # Builds the tagged month page: navigation bar, weekday header, then the
      # day grid (selected day reverse, today underlined). Also refreshes the
      # cached hit-test regions used by the mouse handler.
      private def build_content : String
        nav = navigation_bar_visible?
        header = !horizontal_header_format.no_header?
        weeks = vertical_header_format.iso_week_numbers?
        @grid_top_row = (nav ? 1 : 0) + (header ? 1 : 0)
        @col_offset = weeks ? 3 : 0
        sep = grid_visible? ? glyph(Glyphs::Role::LineVertical) : ' '

        first = local_date(@shown_year, @shown_month, 1)
        dim = Time.days_in_month(@shown_year, @shown_month)
        lead = column_of first
        nrows = (lead + dim + 6) // 7
        # Resolve "today" once per render, not once per cell (up to ~42 `Time.local` calls).
        today = highlight_today? ? Mixin::SectionedField.default_today : nil

        String.build do |io|
          io << build_nav_bar << '\n' if nav

          if header
            io << "Wk " if weeks
            io << weekday_header(sep)
            io << '\n'
          end

          # ISO weeks are identified by their Thursday, not their first day.
          # Under the default Sunday-first calendar the leftmost cell is a
          # Sunday (last day of the *previous* ISO week), so labeling by it
          # would misreport the week (e.g. Jan 1-6 2024 as "52" instead of
          # "1"). Using the row's Thursday is correct for any
          # `#first_day_of_week`. Row-independent, so computed once.
          first_col = first_day_of_week.value % 7
          thursday_offset = (::Time::DayOfWeek::Thursday.value % 7 - first_col + 7) % 7

          nrows.times do |r|
            if weeks
              row_date = first + (r * 7 - lead).days
              # The row's Thursday can land in January of year 10000 for the last
              # grid row of December 9999 (the default `@maximum_date`), which is
              # outside Crystal's `Time` range and raises `ArgumentError`. Fall
              # back to a blank gutter rather than crashing the render/setter path.
              week = begin
                (row_date + thursday_offset.days).calendar_week[1]
              rescue ArgumentError
                nil
              end
              io << (week ? week.to_s.rjust(2) : "  ") << ' '
            end

            7.times do |c|
              d = r * 7 + c - lead + 1
              io << (1 <= d <= dim ? render_day(d, today) : "  ")
              io << sep if c < 6
            end

            io << '\n' unless r == nrows - 1
          end
        end
      end

      # Renders a single day cell, highlighting the selection and today. `today`
      # is resolved once per render by `build_content` (nil when not highlighted).
      private def render_day(d : Int32, today : Time?) : String
        cell = DAY_CELLS[d - 1]
        if selection_mode.single_selection? && @date.year == @shown_year && @date.month == @shown_month && @date.day == d
          "{reverse}#{cell}{/reverse}"
        elsif today && today.year == @shown_year && today.month == @shown_month && today.day == d
          "{underline}#{cell}{/underline}"
        else
          cell
        end
      end

      # Builds the `‹ Month Year ›` navigation bar and records the columns of its
      # arrows / month / year regions for hit-testing.
      private def build_nav_bar : String
        # Center the month name in a fixed `MONTH_FIELD_WIDTH` field so the year
        # and steppers don't shift as months cycle (e.g. "May" vs "September").
        name = MONTHS[@shown_month - 1]
        pad = MONTH_FIELD_WIDTH - name.size
        left_pad = pad // 2
        right_pad = pad - left_pad
        field = "#{" " * left_pad}#{name}#{" " * right_pad}"
        year = @shown_year.to_s

        @nav_prev_col = 0
        month_col = 2 # after "‹ "
        # Whole fixed-width field is the hit-test region, so clicking the padding
        # around a centered short name still opens the dropdown.
        @nav_month_range = (month_col...(month_col + MONTH_FIELD_WIDTH))
        year_col = month_col + MONTH_FIELD_WIDTH + 1 # after the space
        @nav_year_range = (year_col...(year_col + year.size))
        @nav_next_col = year_col + year.size + 1 # after the space

        "‹ #{field} #{year} ›"
      end

      # ── Mouse ─────────────────────────────────────────────────────────────

      private def setup_mouse : Nil
        on(Crysterm::Event::Mouse) do |e|
          next unless e.action.down? || e.action.wheel_up? || e.action.wheel_down?
          handle_mouse e
        end
      end

      private def handle_mouse(e) : Nil
        # Map the pointer through the *painted* position (`@lpos`), not the
        # layout coords (`aleft`/`atop`): inside a scrolled container the painted
        # rect is shifted by the ancestor's scroll base, and mouse dispatch
        # hit-tests against `@lpos`. Mirrors `Mixin::CheckMarker`.
        lpos = @lpos || return
        col = e.x - (lpos.xi + ileft)
        row = e.y - (lpos.yi + itop)
        return if col < 0 || row < 0

        if navigation_bar_visible? && row == 0
          handle_nav_mouse e, col
        else
          handle_grid_mouse e, row - @grid_top_row, col
        end
      rescue
        # Not laid out yet, or out-of-range date; ignore the click.
      end

      private def handle_nav_mouse(e, col : Int32) : Nil
        if e.action.wheel_up? || e.action.wheel_down?
          delta = e.action.wheel_up? ? -1 : 1
          @nav_year_range.includes?(col) ? set_current_page(@shown_year + delta, @shown_month) : shift_page_month(delta)
        elsif col == @nav_prev_col
          show_previous_month
        elsif col == @nav_next_col
          show_next_month
        elsif @nav_year_range.includes? col
          open_year_menu col
        elsif @nav_month_range.includes? col
          open_month_menu col
        else
          return
        end
        e.accept
        request_render
      end

      private def handle_grid_mouse(e, grid_row : Int32, col : Int32) : Nil
        if e.action.wheel_up? || e.action.wheel_down?
          shift_page_month(e.action.wheel_up? ? -1 : 1)
          e.accept
          request_render
        elsif e.action.down? && (d = day_at(grid_row, col))
          activate_day d
          e.accept
          request_render
        end
      end

      # Day number under grid cell (*grid_row*, content column *col*), or `nil`.
      private def day_at(grid_row : Int32, col : Int32) : Int32?
        return nil if grid_row < 0
        rel = col - @col_offset
        return nil if rel < 0
        # Each day cell is 2 columns wide followed by a 1-column separator, so
        # `rel % 3 == 2` is the separator (or trailing blank past the grid): it
        # belongs to no day, and must not hit-test onto the adjacent cell.
        return nil if rel % 3 == 2
        c = rel // 3
        return nil if c > 6

        first = local_date(@shown_year, @shown_month, 1)
        d = grid_row * 7 + c - column_of(first) + 1
        (1 <= d <= Time.days_in_month(@shown_year, @shown_month)) ? d : nil
      end

      # Selects (in `SingleSelection`) and activates day *d* of the shown month.
      private def activate_day(d : Int32) : Nil
        t = local_date(@shown_year, @shown_month, d)
        self.selected_date = t unless selection_mode.no_selection?
        emit Crysterm::Event::Action, clamp_date(t).to_s("%Y-%m-%d")
      end

      # ── Month / year pop-up menus ─────────────────────────────────────────

      # Shared scaffold for the two nav pop-ups: a window-gated, CSS
      # `popup`-classed `Menu` populated by the block, or nil with no window.
      private def new_nav_menu(& : Menu ->) : Menu?
        return unless window?
        menu = Menu.new window: window
        menu.add_css_class "popup"
        yield menu
        menu
      end

      # Number of years on each side of the shown year in the year dropdown
      # (Qt-like span); the menu lists `shown_year - N .. shown_year + N`.
      YEAR_MENU_RADIUS = 100

      private def open_month_menu(col : Int32) : Nil
        # Close the sibling first: the nav bar is part of each open menu's grab
        # region (`popup_nav_menu`), so a click on the year field while the month
        # menu is open passes through instead of dismissing it — without this both
        # dropdowns would end up open with two stacked modal grabs.
        @year_menu.try &.hide_popup
        @month_menu.try &.destroy
        return unless menu = new_nav_menu do |m|
                        MONTHS.each_with_index do |name, i|
                          mo = i + 1
                          # Prefix each name with its zero-padded month number
                          # ("01: January" … "12: December") so the dropdown
                          # carries the same 1-12 numbering the day/year fields do.
                          m.add("#{mo.to_s.rjust(2, '0')}: #{name}") { set_current_page @shown_year, mo; focus }
                        end
                      end
        @month_menu = menu
        # Scroll to / center the currently shown month.
        popup_nav_menu menu, col, @shown_month - 1
      end

      private def open_year_menu(col : Int32) : Nil
        # Close the sibling first (see `#open_month_menu`) so opening one nav
        # dropdown never leaves the other open with a second modal grab.
        @month_menu.try &.hide_popup
        @year_menu.try &.destroy
        return unless menu = new_nav_menu do |m|
                        base = @shown_year
                        (base - YEAR_MENU_RADIUS..base + YEAR_MENU_RADIUS).each do |yr|
                          m.add(yr.to_s) { set_current_page yr, @shown_month; focus }
                        end
                      end
        @year_menu = menu
        # The full ±100 list is far taller than the window; cap visible rows to
        # the space below the nav bar so the dropdown scrolls in-window.
        menu.max_visible_rows = Math.max(1, Math.min(12, (window?.try(&.aheight) || 24) - 3))
        # The shown year sits `YEAR_MENU_RADIUS` rows down; scroll to it so the
        # dropdown opens centered on the current year.
        popup_nav_menu menu, col, YEAR_MENU_RADIUS
      end

      # Floats *menu* under nav column *col* and selects (scrolls to) *index*.
      #
      # Also marks the calendar's nav bar as part of the menu's modal *grab
      # region* (like Qt's `QMenuBar` with its title strip): otherwise the
      # window's modal grab would swallow wheel/click events over the
      # month/year/arrows while the dropdown is open, leaving the wheel "stuck"
      # until an arrow click first dismissed the popup and a second click paged.
      # Including the nav bar in the grab lets `Window#within_grab?` keep
      # delivering to the calendar, while outside clicks (e.g. a day) still
      # dismiss the popup normally.
      private def popup_nav_menu(menu : Menu, col : Int32, index : Int32) : Nil
        menu.treat_as_inside { |x, y| nav_grab_region? x, y }
        # Select *before* showing: `#popup` sizes the menu via `#fit_to_content`,
        # whose height assignment fires the item view's `on_resize`, scrolling
        # the selected row into view — so the long year list opens already
        # scrolled to the current year instead of at its top.
        menu.selekt index
        lpos = @lpos
        if lpos
          menu.popup lpos.xi + ileft + col, lpos.yi + itop + 1
        else
          menu.popup aleft + ileft + col, atop + itop + 1
        end
      end

      # Whether absolute point (*x*, *y*) falls inside an open month/year nav
      # dropdown (its whole submenu chain). An owner that floats the calendar as
      # its own pop-up (e.g. `DateEdit`) folds this into its outside-click
      # dismissal, so clicking a month/year row that overhangs the calendar's own
      # rectangle isn't read as a click-away that tears the calendar down too.
      def nav_popup_contains?(x : Int32, y : Int32) : Bool
        (((m = @month_menu) && m.visible? && m.in_chain?(x, y)) ||
          ((m = @year_menu) && m.visible? && m.in_chain?(x, y))) || false
      end

      # Whether absolute point (*x*, *y*) falls on an interactive region of the
      # nav bar (arrows or month/year fields). Used as the open dropdown's extra
      # grab region (see `#popup_nav_menu`).
      private def nav_grab_region?(x : Int32, y : Int32) : Bool
        return false unless navigation_bar_visible?
        lpos = @lpos || return false
        col = x - (lpos.xi + ileft)
        row = y - (lpos.yi + itop)
        return false unless row == 0
        col == @nav_prev_col || col == @nav_next_col ||
          @nav_month_range.includes?(col) || @nav_year_range.includes?(col)
      rescue
        false # not laid out yet; treat as outside
      end

      # ── Keyboard ──────────────────────────────────────────────────────────

      def on_keypress(e)
        # A display-only calendar (`SelectionMode::NoSelection`) must not move a
        # selection or emit `Event::Action`/`DateChange` from the keyboard —
        # matching `activate_day` (mouse) and `render_day` (marker), which already
        # suppress selection. Leave the keys unaccepted so they can propagate.
        return if selection_mode.no_selection?
        case e.key
        when Tput::Key::Left
          shift_selection_days -1
        when Tput::Key::Right
          shift_selection_days 1
        when Tput::Key::Up
          shift_selection_days -7
        when Tput::Key::Down
          shift_selection_days 7
        when Tput::Key::PageUp
          shift_selection_months -1
        when Tput::Key::PageDown
          shift_selection_months 1
        when Tput::Key::Home
          self.selected_date = local_date(@shown_year, @shown_month, 1)
        when Tput::Key::End
          self.selected_date = local_date(@shown_year, @shown_month, Time.days_in_month(@shown_year, @shown_month))
        when Tput::Key::Enter
          emit Crysterm::Event::Action, @date.to_s("%Y-%m-%d")
        else
          return
        end
        e.accept
        request_render
      rescue
        # `Time.local` unavailable in some headless contexts (see `Mixin::SectionedField.default_today`).
      end

      def destroy
        @month_menu.try &.destroy
        @year_menu.try &.destroy
        @month_menu = nil
        @year_menu = nil
        super
      end
    end
  end
end
