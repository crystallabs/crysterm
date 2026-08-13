module Crysterm
  module Mixin
    # Synthetic keyboard input, for tests, demos and self-driving programs:
    # `press` / `type` build the `Event::KeyPress` and hand it to the
    # includer's `synthesize_key` — on `Window` that is the full input chain
    # (focus-chain walk, per-key events, `Event::Key` fan-out), on `Widget` a
    # direct emit to the widget's own handlers, exactly like a key routed to
    # it.
    #
    # This replaces the long form seen in older examples,
    # `w.emit Event::KeyPress, Event::KeyPress.new(char, key)` — the event
    # class spelled twice for one keystroke.
    module SyntheticInput
      # Synthesizes pressing the key that types *char*: `press 'x'`.
      def press(char : Char) : Nil
        synthesize_key ::Crysterm::Event::KeyPress.new(char)
      end

      # Synthesizes pressing the non-character key *key*:
      # `press Tput::Key::Down` (or `press Key::Down` via the `Crysterm::Key`
      # alias).
      def press(key : ::Tput::Key) : Nil
        synthesize_key ::Crysterm::Event::KeyPress.new('\0', key)
      end

      # Synthesizes pressing the key named by the human-readable *label*, in
      # `Event::KeyPress.parse`'s vocabulary: `press "^X"`, `press "PgDn"`,
      # `press "Enter"`. Raises `ArgumentError` on an unrecognized label (the
      # lenient nil-returning form is `Event::KeyPress.parse` itself).
      def press(label : String) : Nil
        kp = ::Crysterm::Event::KeyPress.parse(label) ||
             raise ArgumentError.new("Unrecognized key label: #{label.inspect}")
        synthesize_key kp
      end

      # Synthesizes typing *text*, one `press` per character.
      def type(text : String) : Nil
        text.each_char { |ch| press ch }
      end
    end
  end
end
