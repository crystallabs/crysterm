require "./abstract_scroll_area"
require "../mixin/interactive"
require "../mixin/text_editing"

module Crysterm
  class Widget
    # Text area element, modeled after Qt's `QPlainTextEdit`.
    #
    # Derives `AbstractScrollArea` (Qt's `QPlainTextEdit < QAbstractScrollArea`,
    # not an input base) and mixes in `Mixin::Interactive` for the focus/keyboard
    # behavior — the editability that, for the simpler controls, comes from
    # `Input`. The text buffer/caret/wrapping/key handling itself lives in
    # `Mixin::TextEditing`, shared with `LineEdit` (an `Input`, not a scroll area).
    #
    # <!-- widget-examples:capture v1 -->
    # ![PlainTextEdit screenshot](../../tests/widget/plaintextedit/plaintextedit.5s.apng)
    # <!-- /widget-examples:capture -->
    class PlainTextEdit < AbstractScrollArea
      include Mixin::Interactive
      include Mixin::TextEditing

      @scrollable = true
      # Single scroll source of truth: `@child_base` (the top visible wrapped
      # row). The interesting position here is the *text caret* (`@cursor_pos`),
      # tracked separately, so — unlike `List`, where `@child_offset` is the
      # selected row — this widget keeps `@child_offset` at 0 (`#scroll` is a pure
      # viewport scroll, `#ensure_cursor_visible` only moves `@child_base`). That
      # makes `get_scroll == child_base`, so the attached `ScrollBar` reflects and
      # drives the viewport top, matching Qt's text-edit behavior (dragging the
      # bar moves the view, not the caret). With one coherent model it can safely
      # default to `AsNeeded`.
      @scrollbar_policy = ScrollBarPolicy::AsNeeded
      # Horizontal scroll only engages with `wrap_content: false` (long lines that
      # run off the right edge); `really_scrollable_x?` is false while wrapping,
      # so this stays inert for the default wrapping editor.
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

      def initialize(
        input_on_focus = false,
        max_length = nil,
        read_only = false,
        **input,
      )
        # Will be taken care of by default above, and parent
        # scrollable.try { |v| @scrollable = v }
        setup_text_buffer(input["content"]? || "", max_length, read_only)

        super **(input.merge({keys: true}))

        # No need to register for keys here: `Widget#initialize` already does
        # that for any widget that asks for keys (`keys`/`input`).

        setup_text_editing input_on_focus: input_on_focus, install_enter: !!input["keys"]?

        # XXX if mouse...
      end
    end
  end
end
