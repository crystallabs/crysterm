require "../widget_effect_direct"

module Crysterm
  class Widget
    # A busy indicator: an animated spinner with an optional message, shown
    # while a long operation runs.
    #
    # `#start` shows it and begins the frame loop, `#stop` stops and hides it.
    # In `#compact?` mode the spinner and the message share one line.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Loading screenshot](../../tests/widget/loading/loading.5s.apng)
    # <!-- /widget-examples:capture -->
    class Loading < Box
      # Self-driven frame loop (`start`/`stop`/`toggle`, `interval`, `running?`).
      # `#start`/`#stop` are overridden below to add the show/content/hide
      # lifecycle around the shared loop.
      include Effect::Animated

      # Built-in spinner animations, selectable by name via the `spinner:`
      # option (or `#spinner=`). The frames of each are cycled by `#step`.
      enum Spinner
        Line
        Dots
        Braille
        Bar
        Circle
        Arrow
        Bounce
        Toggle
      end

      SPINNERS = {
        Spinner::Line    => ["|", "/", "-", "\\"],
        Spinner::Dots    => [".  ", ".. ", "...", " ..", "  .", "   "],
        Spinner::Braille => ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
        Spinner::Bar     => ["[=   ]", "[==  ]", "[ == ]", "[  ==]", "[   =]", "[    ]"],
        Spinner::Circle  => ["◐", "◓", "◑", "◒"],
        Spinner::Arrow   => ["←", "↖", "↑", "↗", "→", "↘", "↓", "↙"],
        Spinner::Bounce  => ["⠁", "⠂", "⠄", "⠂"],
        Spinner::Toggle  => ["▮", "▯"],
      }

      # Frames of a named built-in spinner.
      def self.spinner_frames(spinner : Spinner) : Array(String)
        SPINNERS[spinner]
      end

      property? compact = false

      @orig_text = ""
      @text : String?

      # Cached `"<icon> <text>"` line used by compact-mode `#render`. Rebuilt in
      # the state-change paths rather than interpolated every frame.
      @compact_content = ""

      # Explicitly pinned frames (`frames:`/`spinner:`/`#spinner=`), or `nil` =
      # unset: resolve the CSS `glyphs`/registry chain instead (see `#frames`).
      @frames : Array(String)?

      getter icon : Text

      # The frames currently cycled: the pinned set when one was given, else the
      # CSS `glyphs` string's characters (`Loading { glyphs: "◐◓◑◒" }`), else the
      # registry's `SpinnerFrames` at the effective tier. Memoized, so the
      # per-tick `#step` costs a tuple compare.
      def frames : Array(String)
        if pinned = @frames
          return pinned
        end
        key = glyph_key(style)
        if (f = @_frames) && @_frames_key == key
          return f
        end
        @_frames_key = key
        @_frames = glyph_seq(Glyphs::SeqRole::SpinnerFrames, style).map(&.to_s)
      end

      # :ditto:
      @_frames : Array(String)?
      @_frames_key : {String?, Glyphs::Tier, UInt64}?

      def initialize(
        @compact = false,
        @interval = Crysterm::Config.loading_interval,
        frames : Array(String)? = nil,
        spinner : Spinner? = nil,
        @step = 1,
        **box,
      )
        box["content"]?.try do |c|
          @orig_text = c
        end

        # An explicit `frames:` pins the frames. An *empty* array counts as unset
        # (resolve the default chain), else `frames[0]` would raise `IndexError`
        # here and `#step`'s `% frames.size` a `DivisionByZeroError`.
        @frames = frames.try { |i| i.empty? ? nil : i }

        # A named built-in spinner overrides (and pins) the frames.
        spinner.try { |s| @frames = SPINNERS[s] }

        super **box

        @pos = 0

        # Built with placeholder content: `#frames` is a method call, which can't
        # run until every ivar — `@icon` included — is initialized.
        @icon = Text.new \
          align: :center,
          top: 2,
          left: 1,
          right: 1,
          height: 1,
          content: ""

        @icon.set_content self.frames[0]
        append @icon
        rebuild_compact_content
      end

      # Rebuilds the cached compact-mode line from the current icon frame and
      # text. Called from every path that changes either input.
      private def rebuild_compact_content : Nil
        @compact_content = "#{@icon.content} #{@text || @orig_text}"
      end

      # Switches to a named built-in spinner (see `SPINNERS`) at runtime,
      # restarting its frame cycle.
      def spinner=(name : Spinner)
        frames = SPINNERS[name]
        @frames = frames
        @pos = 0
        @icon.set_content frames[0]
        rebuild_compact_content
      end

      # Shows the widget and starts the spinner loop (`Effect::Animated#start`).
      def start(@text = nil)
        show
        set_content @text || @orig_text
        rebuild_compact_content

        super()
      end

      # Advances the spinner one frame (state + paint only); the shared
      # `Effect::Animated` loop handles `window.render` and the inter-frame sleep.
      #
      # `@pos` is advanced *before* painting: the icon already shows `frames[0]`
      # from `initialize`/`spinner=`, so painting first would freeze the spinner
      # on frame 0 for two intervals.
      def step
        @pos = (@pos + @step) % frames.size
        @icon.set_content frames[@pos]
        rebuild_compact_content
      end

      # Stops the spinner loop and hides the widget.
      def stop
        super
        hide
        @text = nil
        rebuild_compact_content
        request_render
      end

      def render(with_children = true)
        if compact?
          set_content @compact_content, true
          super false
        else
          set_content @text || @orig_text
          super
        end
      end
    end
  end
end
