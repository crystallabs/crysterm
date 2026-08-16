require "../../chat/diff"
require "../message_box"

module Crysterm
  class Widget
    module Chat
      # Chat-flavored permission/confirmation prompts: thin presenters over
      # the stock `MessageBox` dialog. `MessageBox` already carries the
      # OK/Cancel button pair, the y/n/Enter/Escape accelerator and the
      # `DialogButtonBox`-backed multi-choice form, so these helpers only
      # build, size and style — the result protocol and key wiring are
      # inherited unchanged.
      #
      # Every dialog is centered on its window, tag-parsing (so a
      # `Chat::Diff.format` preview renders colored) and tagged with the
      # `popup` CSS class for theming.
      module Dialogs
        # Pops a yes/no confirmation over *window* and delivers the answer to
        # *block* (`MessageBox#open` semantics: Enter/`y`/OK → `true`,
        # Escape/`q`/`n`/Cancel → `false`). Returns the dialog; size defaults
        # fit the text and are overridable via *opts* (any `MessageBox.new`
        # keyword).
        def self.confirm(window : ::Crysterm::Window, text : String, *,
                         ok : String = "Yes", cancel : String = "No",
                         **opts, &block : Bool ->) : MessageBox
          q = build_question window, text, ok, cancel, opts
          q.open(text) { |answer| block.call answer }
          q
        end

        # `confirm` with a colored diff preview under *text* — the
        # "apply this edit?" form. *diff* is unified-diff text, styled via
        # `Chat::Diff.format`; *context* trims hunk context (see
        # `Chat::Diff.trim`).
        def self.confirm_diff(window : ::Crysterm::Window, text : String,
                              diff : String, *, context : Int32? = nil,
                              ok : String = "Yes", cancel : String = "No",
                              **opts, &block : Bool ->) : MessageBox
          # One parse/trim: the tagged body and the plain sizing form are two
          # projections of the same classified lines. Sizing uses the untagged
          # form — tag markup occupies no cells.
          ls = ::Crysterm::Chat::Diff.lines(diff, context: context)
          body = "#{text}\n\n#{ls.join('\n', &.styled)}"
          plain = "#{text}\n\n#{ls.join('\n', &.text)}"
          q = build_question window, plain, ok, cancel, opts
          q.open(body) { |answer| block.call answer }
          q
        end

        # Pops a row of *choices* (a `DialogButtonBox` per `MessageBox#open`'s `choices:` form)
        # and delivers the picked 0-based index — `nil` when dismissed with
        # Escape — to *block*.
        def self.choose(window : ::Crysterm::Window, text : String,
                        choices : Array(String), *, default : Int32 = 0,
                        **opts, &block : Int32? ->) : MessageBox
          q = build_question window, text, nil, nil, opts
          q.open(text, choices: choices, default: default) { |idx| block.call idx }
          q
        end

        # Pops a transient notice via `MessageBox`: dismissed on *time* elapsing,
        # or on the next keypress when *time* is nil/zero.
        def self.notice(window : ::Crysterm::Window, text : String,
                        time : Time::Span? = ::Crysterm::Config.message_display_time,
                        **opts) : MessageBox
          # `MessageBox` already defaults to tag-parsing + shrink-to-fit, so only
          # placement is supplied here.
          merged = {parent: window, top: "center", left: "center"}.merge(opts)
          m = MessageBox.new(**merged)
          m.add_css_class "popup"
          m.open text, time
          m
        end

        # Builds the shared centered, tag-parsing, `popup`-classed `MessageBox`,
        # sized to *measure* unless *opts* override.
        private def self.build_question(window, measure : String, ok, cancel, opts) : MessageBox
          width, height = fit window, measure
          merged = {parent: window, top: "center", left: "center",
                    width: width, height: height, parse_tags: true}.merge(opts)
          q = MessageBox.new(ok, cancel, **merged)
          q.add_css_class "popup"
          q
        end

        # Default dialog size for *text*: content extent plus frame and the
        # button row, clamped to the window.
        private def self.fit(window : ::Crysterm::Window, text : String) : {Int32, Int32}
          lines = text.split '\n'
          widest = lines.max_of { |l| ::Crysterm::Unicode.display_width l }
          width = (widest + 6).clamp(24, {24, window.awidth - 2}.max)
          height = (lines.size + 5).clamp(6, {6, window.aheight - 2}.max)
          {width, height}
        end
      end
    end
  end
end
