require "./effect/animated"

module Crysterm
  class Widget
    # Box element
    class Loading < Box
      # Self-driven frame loop (`start`/`stop`/`toggle`, `interval`, `running?`).
      # `#step` advances the spinner one frame; `#start`/`#stop` are overridden
      # below to add the show/content/hide lifecycle around the shared loop.
      include Effect::Animated

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
        @step = 1,
        **box,
      )
        box["content"]?.try do |c|
          @orig_text = c
        end

        super **box

        @pos = 0 # @step > 0 ? (@step - 1) : @step

        @icon = Text.new \
          align: :center,
          top: 2,
          left: 1,
          right: 1,
          height: 1,
          content: @icons[0]

        append @icon
      end

      # Blessed-compatible alias for `#start` (Blessed's Loading uses
      # `load`/`stop`; Crysterm names them `start`/`stop`).
      def load(text = nil)
        start text
      end

      # Shows the widget and starts the spinner loop (`Effect::Animated#start`).
      def start(@text = nil)
        # D O:
        # Keep on top:
        # @parent.try do |p|
        #   detach
        #   p.append self
        # end

        show
        set_content @text || @orig_text

        # XXX We don't want to do this? (Blessed does it)
        # @screen.propagate_keys = false

        super()
      end

      alias_previous :load

      # Advances the spinner one frame (state + paint only); the shared
      # `Effect::Animated` loop handles `screen.render` and the inter-frame sleep.
      def step
        @icon.set_content icons[@pos]
        @pos = (@pos + @step) % icons.size
      end

      # Stops the spinner loop and hides the widget.
      def stop
        # XXX We don't want to do this? (Blessed does it)
        # @screen.propagate_keys = true
        super
        hide
        @text = nil
        screen.render
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
