module Crysterm
  class Widget
    module Pine
      # A one-line "press a key to answer" prompt, modeled on Alpine's
      # bottom-of-screen key-choice prompt (the `radio_buttons` mechanism in
      # `radio.c`). Shows a question followed by single-key choices, highlights
      # the chosen key, runs that choice's callback, and remembers the answer.
      #
      # ```
      #   Expunge the selected items? [y/n]
      #   └──── question ──────────┘ └ choices ┘
      # ```
      #
      # Generic: a `question` string plus any set of `Choice`s (each a
      # single-key `key`, a short `label`, and an optional `callback`).
      #
      # When the user presses a key matching a choice, that choice becomes the
      # `#answer`, its `callback` runs, and the widget emits `Event::Activated`
      # with the chosen key. It must have focus to receive keys.
      #
      # ```
      # prompt = Widget::Pine::KeyPrompt.new "Save changes?", [
      #   Widget::Pine::KeyPrompt::Choice.new("Y", "Yes") { save },
      #   Widget::Pine::KeyPrompt::Choice.new("N", "No"),
      #   Widget::Pine::KeyPrompt::Choice.new("C", "Cancel"),
      # ], parent: screen, bottom: 0
      # prompt.on(Crysterm::Event::Activated) { |e| puts "answered #{e.value}" }
      # prompt.focus
      # ```
      #
      # The convenience `KeyPrompt.yes_no` builds a two-choice yes/no prompt.
      #
      # <!-- widget-examples:capture v1 -->
      # ![KeyPrompt screenshot](../../../tests/widget/pine/key_prompt/key_prompt.5s.apng)
      # <!-- /widget-examples:capture -->
      class KeyPrompt < Widget::Box
        include KeyBar

        # A single key-choice the user can pick.
        alias Choice = KeyBar::Item

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
          # `keys: true` is required: a plain `Box` never receives `Event::KeyPress`.
          super **layout, width: w, height: h, parse_tags: true, keys: true
          # Flow the question + choice boxes left-to-right. Assigned to the ivar
          # so it is in place before `rebuild` appends children.
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
        def question=(question : String)
          @question = question
          rebuild
        end

        # Replaces the choices and redraws the line.
        def choices=(choices : Array(Choice))
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
          # Compare as `Char`s: a `String` comparison would allocate per keypress
          # and per choice.
          dc = char.downcase
          choice = @choices.find { |c| c.key.size == 1 && c.key[0].downcase == dc }
          return unless choice
          # Accept so the default quit-key fallback in Application#route_input
          # doesn't also quit the app when a choice happens to be keyed 'q'.
          e.accept
          choose choice
        end

        # Records *choice* as the `#answer`, runs its callback, and emits
        # `Event::Activated` with the chosen key.
        def choose(choice : Choice) : Nil
          @answer = choice.key
          choice.callback.try &.call
          emit ::Crysterm::Event::Activated, choice.key
          request_render
        end

        # (Re)creates the child boxes: an optional question box, then one
        # clickable box per choice. `focus_on_click` is off so a click doesn't
        # pull focus off the prompt.
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

          @choices.each do |choice|
            content = format_entry(choice)
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
      end
    end
  end
end
