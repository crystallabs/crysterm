require "../widget_effect_direct"

module Crysterm
  class Widget
    # Box element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Loading screenshot](../../tests/widget/loading/loading.5s.apng)
    # <!-- /widget-examples:capture -->
    class Loading < Box
      # Self-driven frame loop (`start`/`stop`/`toggle`, `interval`, `running?`).
      # `#step` advances the spinner one frame; `#start`/`#stop` are overridden
      # below to add the show/content/hide lifecycle around the shared loop.
      include Effect::Animated

      # Built-in spinner animations, selectable by name via the `spinner:`
      # option (or `#spinner=`). The frames of each are cycled by `#step`.
      SPINNERS = {
        "line"    => ["|", "/", "-", "\\"],
        "dots"    => [".  ", ".. ", "...", " ..", "  .", "   "],
        "braille" => ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
        "bar"     => ["[=   ]", "[==  ]", "[ == ]", "[  ==]", "[   =]", "[    ]"],
        "circle"  => ["◐", "◓", "◑", "◒"],
        "arrow"   => ["←", "↖", "↑", "↗", "→", "↘", "↓", "↙"],
        "bounce"  => ["⠁", "⠂", "⠄", "⠂"],
        "toggle"  => ["▮", "▯"],
      }

      # Frames of a named built-in spinner, or `nil` if the name is unknown.
      def self.spinner_frames(name : String | Symbol) : Array(String)?
        SPINNERS[name.to_s]?
      end

      property? compact = false

      @orig_text = ""
      @text : String?

      # Cached `"<icon> <text>"` line used by compact-mode `#render`. Rebuilt in
      # the state-change paths (`#step`, `#start`, `#stop`, `#spinner=`) rather
      # than interpolated afresh every frame — the text only changes on a spinner
      # tick (~14 fps max) or a start/stop, not per render.
      @compact_content = ""

      # XXX Use a better name than 'icons', so that it doesn't
      # seem to imply longer text can't be used.

      # Explicitly pinned frames (`icons:`/`spinner:`/`#spinner=`), or `nil` =
      # unset: resolve the CSS `glyphs`/registry chain instead (see `#icons`).
      @icons : Array(String)?

      getter icon : Text

      # The frames currently cycled: the pinned set when one was given, else
      # the CSS `glyphs` string's characters (`Loading { glyphs: "◐◓◑◒" }`),
      # else the registry's `SpinnerFrames` at the effective tier (`| / - \`
      # everywhere but tier Extended, whose default upgrade is the braille
      # ring). The resolved set is memoized against everything it derives
      # from, so the per-tick `#step` costs a tuple compare.
      def icons : Array(String)
        if pinned = @icons
          return pinned
        end
        key = {style.glyphs, glyph_tier, Glyphs.generation}
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
        icons : Array(String)? = nil,
        spinner : String | Symbol | Nil = nil,
        @step = 1,
        **box,
      )
        box["content"]?.try do |c|
          @orig_text = c
        end

        # An explicit `icons:` pins the frames; an *empty* array would make
        # `icons[0]` below raise `IndexError` at construction (and later
        # `#step`'s `% icons.size` a `DivisionByZeroError`), so it counts as
        # unset — resolve the default chain instead, mirroring how the
        # block-glyph charts treat empty color arrays as "use the default".
        @icons = icons.try { |i| i.empty? ? nil : i }

        # A named built-in spinner overrides (and pins) the frames.
        spinner.try { |name| SPINNERS[name.to_s]?.try { |f| @icons = f } }

        super **box

        @pos = 0

        # Built with placeholder content: the frame resolution (`#icons`) is a
        # method call, which can't run until every ivar — `@icon` included —
        # is initialized.
        @icon = Text.new \
          align: :center,
          top: 2,
          left: 1,
          right: 1,
          height: 1,
          content: ""

        @icon.set_content self.icons[0]
        append @icon
        rebuild_compact_content
      end

      # Rebuilds the cached compact-mode line from the current icon frame and
      # text. Called from every path that changes either input.
      private def rebuild_compact_content : Nil
        @compact_content = "#{@icon.content} #{@text || @orig_text}"
      end

      # Switches to a named built-in spinner (see `SPINNERS`) at runtime,
      # restarting its frame cycle. Unknown names are ignored.
      def spinner=(name : String | Symbol)
        SPINNERS[name.to_s]?.try do |frames|
          @icons = frames
          @pos = 0
          @icon.set_content frames[0]
          rebuild_compact_content
        end
      end

      # Blessed-compatible alias for `#start` (Blessed's Loading uses
      # `load`/`stop`; Crysterm names them `start`/`stop`).
      def load(text = nil)
        start text
      end

      # Shows the widget and starts the spinner loop (`Effect::Animated#start`).
      def start(@text = nil)
        show
        set_content @text || @orig_text
        rebuild_compact_content

        # XXX We don't want to do this? (Blessed does it)
        # @window.propagate_keys = false

        super()
      end

      # Advances the spinner one frame (state + paint only); the shared
      # `Effect::Animated` loop handles `window.render` and the inter-frame sleep.
      #
      # `@pos` is advanced *before* painting: the icon already shows `icons[0]`
      # from `initialize`/`spinner=`, so painting `icons[@pos]` first would
      # re-draw the same frame on the very first tick, freezing the spinner on
      # frame 0 for two intervals. Stepping first makes the first tick advance
      # to `icons[1]`, so every interval shows a new frame.
      def step
        @pos = (@pos + @step) % icons.size
        @icon.set_content icons[@pos]
        rebuild_compact_content
      end

      # Stops the spinner loop and hides the widget.
      def stop
        # XXX We don't want to do this? (Blessed does it)
        # @window.propagate_keys = true
        super
        hide
        @text = nil
        rebuild_compact_content
        request_render
      end

      def render
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
