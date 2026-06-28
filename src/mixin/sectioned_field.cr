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
          if e.action.wheel_up?
            focus
            select_section_at e.x
            on_section_wheel
            step 1
            e.accept
            request_render
          elsif e.action.wheel_down?
            focus
            select_section_at e.x
            on_section_wheel
            step -1
            e.accept
            request_render
          elsif e.action.down?
            focus
            select_section_at e.x
            on_section_press
            e.accept
            request_render
          end
        end
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
