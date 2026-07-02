module Crysterm
  module Mixin
    # Shared behavior for the fixed-layout, multi-section value editors
    # `Widget::DateEdit` (`YYYY-MM-DD`) and `Widget::TimeEdit` (`HH:MM:SS`).
    #
    # Provides an integer `@section` cursor over the value's parts plus the common
    # interaction: select the section under a click/wheel, move between sections
    # with Left/Right, and step the active section with Up/Down or the mouse
    # wheel. Each mouse interaction grabs focus first (like a slider/dropdown) so
    # the keyboard then drives the field.
    #
    # The including widget must define:
    #   * `section_count : Int32`          — number of sections;
    #   * `section_at(x : Int32) : Int32?` — section index under absolute *x*
    #                                        (`nil` when off the field);
    #   * `step(delta : Int32)`            — step the active section by ±1;
    #   * `update_content`                 — repaint, highlighting `@section`.
    # `section_at` is usually a one-liner over `#section_from_columns` (only the
    # per-editor column layout differs), and `step` over `#step_time_field` (only
    # which `Time` field each `@section` maps to differs).
    # It may override `on_section_press`/`on_section_wheel` to add behavior (e.g.
    # `DateEdit` toggles/closes its calendar popup), and calls
    # `setup_section_mouse` from its constructor.
    module SectionedField
      # Active section index (which part of the value the keyboard edits).
      @section : Int32 = 0

      # Installs the shared mouse handler. Call from `initialize` after `super`
      # (the keyboard handler is wired by the widget's own `handle KeyPress`).
      #
      # `Mouse` (not `Click`) because only it carries the coordinates used to pick
      # the section under the pointer.
      private def setup_section_mouse : Nil
        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up? || e.action.wheel_down?
            # Up and down notches share the whole focus/select/step/accept path,
            # differing only in the step direction; merging them keeps the two
            # from drifting out of sync.
            section_interaction(e) do
              on_section_wheel
              step(e.action.wheel_up? ? 1 : -1)
            end
          elsif e.action.down?
            section_interaction(e) { on_section_press }
          end
        end
      end

      # Focuses the field, selects the section under the pointer (*e*.x), runs the
      # interaction-specific *block* (a wheel step, or the press hook), then
      # accepts the event and repaints — the focus/select/…/accept/render scaffold
      # the wheel and press branches otherwise repeat (cf.
      # `SpinBoxEditing#stepping_key`). Block-yielding, so it allocates no `Proc`.
      private def section_interaction(e, &) : Nil
        focus
        select_section_at e.x
        yield
        e.accept
        request_render
      end

      # Maps an absolute *x* to a section index given each section's inclusive
      # end-column *ends* (ascending; `ends[i]` is the last column belonging to
      # section `i`). Returns `nil` when *x* is left of the field or right of
      # `ends[-1]` (past the text) — `select_section_at` relies on that `nil` to
      # leave the active section untouched on a click past the value. Single-sources
      # the column arithmetic and the right-edge guard that `DateEdit`/`TimeEdit`/
      # `DateTimeEdit` otherwise copied (the "return nil past the text" fix had been
      # pasted into all three `section_at`s).
      private def section_from_columns(x : Int32, ends : Array(Int32)) : Int32?
        col = x - aleft - ileft
        return nil if col < 0 || col > ends[-1]
        ends.index { |e| col <= e }
      rescue
        nil
      end

      # Steps one calendar field of *t* by *delta*, wrapping within that field's
      # own range without carrying into the next (year is only clamped to `Time`'s
      # supported 1..9999). The day is then re-clamped to the (possibly shorter)
      # resulting month so the `Time` stays valid. *field* is the absolute
      # component index — 0=year 1=month 2=day 3=hour 4=minute 5=second — so each
      # editor maps its `@section` onto it (`DateEdit` 1:1, `TimeEdit` +3,
      # `DateTimeEdit` 1:1). Single-sources the stepping body (and the day-overflow
      # clamp `date_edit.cr`/`date_time_edit.cr` had verbatim) the three editors
      # otherwise re-implement per-field.
      protected def step_time_field(t : Time, field : Int32, delta : Int32) : Time
        y, mo, d = t.year, t.month, t.day
        h, mi, s = t.hour, t.minute, t.second
        dim = nil
        case field
        when 0 then y = (y + delta).clamp(1, 9999)
        when 1 then mo = wrap(mo - 1, delta, 12) + 1
        when 2 then d = wrap(d - 1, delta, dim = Time.days_in_month(y, mo)) + 1
        when 3 then h = wrap(h, delta, 24)
        when 4 then mi = wrap(mi, delta, 60)
        else        s = wrap(s, delta, 60)
        end
        # Year/month branches changed y/mo, so recompute days-in-month if unset.
        d = Math.min(d, dim || Time.days_in_month(y, mo))
        Time.local(y, mo, d, h, mi, s)
      end

      # Selects the section under absolute *x* (no-op when off the field or
      # already current).
      private def select_section_at(x : Int32) : Nil
        if sec = section_at(x)
          return if sec == @section
          @section = sec
          update_content
        end
      end

      # Moves the section cursor by *delta*, clamped into range.
      private def move_section(delta : Int32) : Nil
        @section = (@section + delta).clamp(0, section_count - 1)
        update_content
      end

      # Handles the section keys shared by both editors: Left/Right move the
      # cursor, Up/Down step the active section. Returns whether the key was
      # consumed, so the including `on_keypress` can layer its own extra keys.
      private def handle_section_key(e) : Bool
        case e.key
        when ::Tput::Key::Left  then move_section -1
        when ::Tput::Key::Right then move_section 1
        when ::Tput::Key::Up    then step 1
        when ::Tput::Key::Down  then step -1
        else
          return false
        end
        e.accept
        request_render
        true
      end

      # Adds *delta* to *v* modulo *mod*, staying in `0...mod` (the no-carry
      # step convention shared by every section editor). Used by each widget's
      # `step` to wrap minutes/months/etc. within their own range.
      private def wrap(v : Int32, delta : Int32, mod : Int32) : Int32
        r = (v + delta) % mod
        r < 0 ? r + mod : r
      end

      # Highlights the active section in place by wrapping `parts[@section]` in
      # `{reverse}…{/reverse}`, guarded to the array bounds, and returns *parts*
      # so the caller can join them with its own separators.
      private def highlight_part(parts : Array(String)) : Array(String)
        if 0 <= @section < parts.size
          parts[@section] = "{reverse}#{parts[@section]}{/reverse}"
        end
        parts
      end

      # Commits a changed value: repaints (highlighting the active section),
      # emits `Event::DateChange` carrying *value*, and requests a render. Each
      # editor's value setter calls this after storing the new value, replacing
      # the identical update/emit/render trio they otherwise repeat.
      protected def commit_value(value : Time) : Nil
        update_content
        emit Crysterm::Event::DateChange, value
        request_render
      end

      # Hook run after a press selects a section. Default: nothing.
      protected def on_section_press : Nil
      end

      # Hook run after a wheel selects a section, before stepping. Default:
      # nothing.
      protected def on_section_wheel : Nil
      end
    end
  end
end
