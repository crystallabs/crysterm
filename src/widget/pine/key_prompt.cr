module Crysterm
  class Widget
    module Pine
      # A one-line "press a key to answer" prompt, modeled on Alpine's
      # bottom-of-screen key-choice prompt (the `radio_buttons` mechanism in
      # `radio.c`). It shows a question followed by a set of single-key choices,
      # highlights the chosen key, runs that choice's callback, and remembers the
      # answer.
      #
      # ```
      #   Expunge the selected items? [y/n]
      #   └──── question ──────────┘ └ choices ┘
      # ```
      #
      # It is completely generic: a `question` string plus any set of
      # `Choice`s (each a single-key `key`, a short `label`, and an optional
      # `callback`). It is not tied to any particular domain.
      #
      # When the user presses a key matching one of the choices, that choice
      # becomes the `#answer`, its `callback` runs, and the widget emits
      # `Event::Action` with the chosen key, so callers can react with a handler
      # instead of (or in addition to) the per-choice callback. Wire it up by
      # giving the widget focus, the same as any other interactive widget.
      #
      # ```
      # prompt = Widget::Pine::KeyPrompt.new "Save changes?", [
      #   Widget::Pine::KeyPrompt::Choice.new("Y", "Yes", -> { save }),
      #   Widget::Pine::KeyPrompt::Choice.new("N", "No"),
      #   Widget::Pine::KeyPrompt::Choice.new("C", "Cancel"),
      # ], parent: screen, bottom: 0
      # prompt.on(Crysterm::Event::Action) { |e| puts "answered #{e.value}" }
      # prompt.focus
      # ```
      #
      # The convenience `KeyPrompt.yes_no` builds a two-choice yes/no prompt.
      #
      # <!-- widget-examples:capture v1 -->
      # ![KeyPrompt screenshot](../../../tests/widget/pine/key_prompt/key_prompt.5s.apng)
      # <!-- /widget-examples:capture -->
      class KeyPrompt < Widget::Box
        # A single key-choice the user can pick.
        class Choice
          # The keyboard key that selects this choice (shown highlighted).
          property key : String

          # Human-readable description shown next to the key.
          property label : String

          # Optional action invoked when this choice is selected.
          property callback : Proc(Nil)?

          def initialize(@key, @label, @callback = nil)
          end
        end

        # The question shown at the start of the line.
        getter question : String

        # The choices the user can pick from.
        getter choices : Array(Choice)

        # Style used to highlight each choice's key character.
        property key_style : Style

        # The `key` of the choice the user picked, or `nil` until they answer.
        getter answer : String?

        # The child boxes: an optional question box plus one clickable box per
        # choice (parallel to `#choices`).
        getter cells = [] of Widget::Box

        def initialize(
          @question : String = "",
          choices : Array(Choice) = [] of Choice,
          *,
          @key_style = Style.new(reverse: true),
          height h = 1, width w = "100%",
          **layout,
        )
          @choices = choices
          # `keys: true` registers the prompt as keyable so the screen dispatches
          # key presses to it once it is focused — without it a plain `Box` never
          # receives `Event::KeyPress`, and the choice keys (Y/N/…) do nothing.
          super **layout, width: w, height: h, parse_tags: true, keys: true
          # Flow the question + choice boxes left-to-right (like `HeaderBar`), so
          # each choice is a real child that can be clicked. Set the ivar directly
          # so it is in place before `#rebuild` appends children.
          @layout = Crysterm::Layout::Masonry.new
          rebuild
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        # Builds a generic yes/no prompt. The `yes`/`no` callbacks (if given) run
        # when the respective choice is picked.
        def self.yes_no(
          question : String,
          *,
          yes_label = "Yes",
          no_label = "No",
          yes : Proc(Nil)? = nil,
          no : Proc(Nil)? = nil,
          **opts,
        ) : self
          new question, [
            Choice.new("Y", yes_label, yes),
            Choice.new("N", no_label, no),
          ], **opts
        end

        # Replaces the question text and redraws the line.
        def set_question(question : String)
          @question = question
          rebuild
        end

        # Replaces the choices and redraws the line.
        def set_choices(choices : Array(Choice))
          @choices = choices
          rebuild
        end

        # Returns the `Choice` the user picked, if any.
        def answered_choice : Choice?
          a = @answer
          return nil unless a
          @choices.find { |c| c.key == a }
        end

        # Selects the choice whose `key` matches the pressed character (case
        # insensitively); other keys are ignored.
        def on_keypress(e)
          char = e.char
          return if char == '\0'
          target = char.to_s.downcase
          choice = @choices.find { |c| c.key.downcase == target }
          return unless choice
          choose choice
        end

        # Records *choice* as the `#answer`, runs its callback, and emits
        # `Event::Action` with the chosen key.
        def choose(choice : Choice) : Nil
          @answer = choice.key
          choice.callback.try &.call
          emit ::Crysterm::Event::Action, choice.key
          request_render
        end

        # (Re)creates the child boxes: an optional question box, then one box per
        # choice rendered as a highlighted key plus its label (the `KeyMenu`
        # look). Each choice box is clickable — clicking it picks that choice —
        # and `focus_on_click` is off so a click doesn't pull focus off the
        # prompt (which holds the keyboard).
        private def rebuild : Nil
          @cells.each &.remove_from_parent
          @cells.clear

          unless @question.empty?
            q = Widget::Box.new(
              window: window, height: 1, width: @question.size + 1, content: @question,
            )
            append q
            @cells << q
          end

          tags = key_tags
          @choices.each do |choice|
            content = "#{tags[:open]} #{choice.key} #{tags[:close]} #{choice.label}"
            # Visible width: " key " + " label" (tags add no columns), + a gap.
            width = choice.key.size + choice.label.size + 5
            box = Widget::Box.new(
              window: window, height: 1, width: width,
              parse_tags: true, content: content, focus_on_click: false,
            )
            box.on(::Crysterm::Event::Click) { choose(choice) }
            append box
            @cells << box
          end
          request_render
        end

        # Translates `key_style` into open/close tags used around the key,
        # matching `KeyMenu`.
        private def key_tags
          if @key_style.reverse?
            {open: "{reverse}", close: "{/reverse}"}
          elsif (fg = @key_style.fg) && fg >= 0
            hex = "#%06x" % (fg & 0xffffff)
            {open: "{#{hex}-fg}", close: "{/#{hex}-fg}"}
          else
            {open: "{bold}", close: "{/bold}"}
          end
        end
      end
    end
  end
end
