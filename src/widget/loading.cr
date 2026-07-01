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

      # XXX Use a better name than 'icons', so that it doesn't
      # seem to imply longer text can't be used.

      getter icons : Array(String)
      getter icon : Text

      def initialize(
        @compact = false,
        @interval = Crysterm::Config.loading_interval,
        @icons = ["|", "/", "-", "\\"],
        spinner : String | Symbol | Nil = nil,
        @step = 1,
        **box,
      )
        box["content"]?.try do |c|
          @orig_text = c
        end

        # A named built-in spinner overrides the default frames.
        spinner.try { |name| SPINNERS[name.to_s]?.try { |f| @icons = f } }

        super **box

        @pos = 0

        @icon = Text.new \
          align: :center,
          top: 2,
          left: 1,
          right: 1,
          height: 1,
          content: @icons[0]

        append @icon
      end

      # Switches to a named built-in spinner (see `SPINNERS`) at runtime,
      # restarting its frame cycle. Unknown names are ignored.
      def spinner=(name : String | Symbol)
        SPINNERS[name.to_s]?.try do |frames|
          @icons = frames
          @pos = 0
          @icon.set_content frames[0]
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
      end

      # Stops the spinner loop and hides the widget.
      def stop
        # XXX We don't want to do this? (Blessed does it)
        # @window.propagate_keys = true
        super
        hide
        @text = nil
        request_render
      end

      def render
        if compact?
          set_content "#{@icon.content} #{@text || @orig_text}", true
          super false
        else
          set_content @text || @orig_text
          super
        end
      end
    end
  end
end
