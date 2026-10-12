require "./box"
require "./line_edit"
require "../layout/hbox"

module Crysterm
  class Widget
    # A one-row prompt in the manner of vi's command line (`:w name`): a label
    # at the left and an inline `LineEdit` filling the rest of the row, shown
    # only while a question is open. `#prompt` asks; Enter answers with the entered text and
    # Escape — or Backspace on an empty line, as in vi — answers with `nil`.
    # Focus returns to the widget that had it. The field keeps a shell-style
    # Up/Down history across prompts, and with a `#completer` Tab and
    # Shift+Tab cycle through completions of the text typed so far.
    #
    # Where it goes is the host's business — typically in place of a status
    # bar, which is what `StatusBar#prompt` does — so the widget is a plain
    # one-row `Box` an app can place anywhere. It asks the same question an
    # `InputDialog` (and `Window#prompt`) asks in a dialog, inline.
    #
    # ```
    # cl = Widget::LinePrompt.new parent: window, bottom: 0, left: 0, width: "100%"
    # cl.completer = Widget::LinePrompt.path_completer
    # cl.prompt("Save as: ", "notes.md") { |path| save path if path }
    # ```
    #
    # Emits `Event::Submitted` with the answer, or `Event::Cancelled`, before
    # the callback runs.
    #
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    class LinePrompt < Box
      # The label at the left, sized to its text. (`#label` is the border
      # label every widget has.)
      getter label_box : Box

      # The inline field.
      getter field : LineEdit

      # Completions for the text typed so far, for Tab/Shift+Tab; `nil` for
      # none. Called with the field's text on the first Tab of a run and
      # returns the candidates in cycling order. A lone candidate is taken
      # outright and the next Tab completes it further.
      property completer : Proc(String, Array(String))?

      # The open question's completer (`#prompt`'s *completer*).
      @question_completer : Proc(String, Array(String))?

      # A `#completer` for file system paths, as a shell completes them: the
      # entries matching the text typed so far, sorted, with a trailing `/`
      # on directories so that the next Tab descends into them. A leading
      # `~` stands for the home directory and is expanded in the
      # completions. Glob characters in the text are taken literally.
      #
      # ```
      # cl.completer = Widget::LinePrompt.path_completer
      # ```
      def self.path_completer : Proc(String, Array(String))
        ->(text : String) do
          expanded = if text == "~" || text.starts_with?("~/")
                       Path.home.to_s + text[1..]
                     else
                       text
                     end
          pattern = expanded.gsub(/[*?\[\]{}\\]/) { |c| "\\#{c}" }
          Dir.glob("#{pattern}*").sort.map do |path|
            File.directory?(path) ? "#{path}/" : path
          end
        end
      end

      # Whether a question is open.
      getter? active : Bool = false

      @callback : Proc(String?, Nil)?
      @matches = [] of String
      @match_index = 0
      @completing = false

      def initialize(**box)
        @label_box = Box.new height: 1, width: 0
        # Reading starts from `#prompt`, not from focus, so a stray focus
        # (Tab navigation) never opens a read with no question behind it.
        @field = LineEdit.new height: 1, input_on_focus: false
        super(**{height: 1, width: "100%"}.merge(box))
        self.layout = Layout::HBox.new
        append @label_box
        append @field
        hide
        @field.on(Crysterm::Event::KeyPress) { |e| field_key e }
      end

      # Asks *label*, with the field starting at *value* (the caret at its end),
      # and delivers the answer to *callback*: the entered text, or `nil` when
      # cancelled. A question already open is cancelled first. *completer*
      # completes this question's Tab and Shift+Tab, by default the prompt's
      # `#completer` (`nil`: none) — a question asking for something else
      # than the usual, a command name rather than a file, brings its own.
      def prompt(label : String, value : String = "", *, completer : Proc(String, Array(String))? = @completer, &callback : String? ->) : Nil
        cancel
        @active = true
        @callback = callback
        @question_completer = completer
        @label_box.set_content label
        @label_box.width = str_width label
        @field.value = value
        end_completion
        show
        @field.read_input { |data| finish data }
        update!
      end

      # Cancels the open question, if any: the callback receives `nil`.
      def cancel : Nil
        return unless @active
        # Hiding ends the field's read by blur, which answers `nil`.
        hide
        finish nil
      end

      private def finish(data : String?) : Nil
        return unless @active
        @active = false
        callback = @callback
        @callback = nil
        @question_completer = nil
        end_completion
        # Focus rewinds out of the hidden row to the widget that had it.
        hide
        update!
        if data
          emit Crysterm::Event::Submitted, data
        else
          emit Crysterm::Event::Cancelled
        end
        callback.try &.call data
      end

      # The line-prompt keys on top of the field's own: Tab/Shift+Tab cycle
      # completions, Backspace on an empty line cancels. Any other key ends a
      # completion run, so the next Tab completes the edited text afresh.
      # Registered at construction, so it runs before the read's listener.
      #
      # Every key is accepted: an open question owns the keyboard, as vi's
      # command line does, so the window-level accelerators that fire on keys
      # the focused widget leaves alone — `Action` shortcuts, a menu bar's
      # activation key and mnemonics — stand down until the answer, the way
      # Qt's shortcuts stand down while a modal dialog is up. The field's own
      # reading is unaffected: its listener runs on the same emission
      # whatever the event's state, and the keys it handles it accepts anyway.
      private def field_key(e : Crysterm::Event::KeyPress) : Nil
        return unless @active
        e.accept
        case e.key
        when Tput::Key::Tab
          complete 1
        when Tput::Key::ShiftTab
          complete -1
        when Tput::Key::Backspace, Tput::Key::CtrlH
          if @field.value.empty?
            cancel
          else
            end_completion
          end
        else
          end_completion
        end
      end

      # Steps the completion run by *dir*, starting one from the field's text.
      # A lone completion is taken and the run ends with it, so the next Tab
      # completes the new text afresh — a shell's `/t` → `/tmp/` → the
      # entries under it. A run only cycles when there is something to cycle.
      private def complete(dir : Int32) : Nil
        return unless completer = @question_completer
        unless @completing
          @matches = completer.call @field.value
          return if @matches.empty?
          if @matches.size == 1
            @field.value = @matches[0]
            end_completion
            return
          end
          @completing = true
          @match_index = dir > 0 ? -1 : 0
        end
        @match_index = (@match_index + dir) % @matches.size
        @field.value = @matches[@match_index]
      end

      # The matches are let go, not cleared: the list may be the completer's
      # own (a fixed set of names it returns as is), which is not ours to empty.
      private def end_completion : Nil
        @completing = false
        @matches = [] of String unless @matches.empty?
      end
    end
  end
end
