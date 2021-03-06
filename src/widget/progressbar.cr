require "./node"
require "./element"

module Crysterm
  module Widget
    class ProgressBar < Input
      property filled : Int32 = 0
      property value : Int32 = 0
      property pch : Char = ' '
      property orientation : Orientation = Orientation::Horizontal

      # TODO Add new options:
      # min value and max value
      # step of increase
      # does it wrap around?
      # does it print value and/or percentage
      # can it auto-resize based on amount
      # always track of how many % a certain value is

      # XXX Change this to enabled? later.
      property keys : Bool = true
      property mouse : Bool = false

      def initialize(
        @filled = 0,
        @pch = ' ',
        @keys = true,
        @mouse = false,
        orientation = nil,
        **input
      )
        super **input

        orientation.try { |v| @orientation = v }

        @value = @filled

        if @keys
          on(KeyPressEvent) do |e|
            # Since the keys aren't conflicting, support both regardless
            # of orientation.
            # case @orientation
            # when Orientation::Vertical
            #  back_keys = [Tput::Key::Down]
            #  back_chars = ['j']
            #  forward_keys = [Tput::Key::Up]
            #  forward_chars = ['k']
            # else #when Orientation::Horizontal
            #  back_keys = [Tput::Key::Left]
            #  back_chars = ['h']
            #  forward_keys = [Tput::Key::Right]
            #  forward_chars = ['l']
            # end

            back_keys = [Tput::Key::Left, Tput::Key::Down]
            back_chars = ['h', 'j']
            forward_keys = [Tput::Key::Right, Tput::Key::Up]
            forward_chars = ['l', 'k']

            if back_keys.includes?(e.key) || back_chars.includes?(e.char)
              progress -5
              @screen.render
              next
            elsif forward_keys.includes?(e.key) || forward_chars.includes?(e.char)
              progress 5
              @screen.render
              next
            end
          end
        end

        if @mouse
          # XXX ...
        end
      end

      def render
        ret = _render
        return unless ret

        xi = ret.xi
        xl = ret.xl
        yi = ret.yi
        yl = ret.yl

        if @border
          xi += 1
          yi += 1
          xl -= 1
          yl -= 1
        end

        if @orientation == Orientation::Horizontal
          xl = xi + ((xl - xi) * (@filled / 100)).to_i
        else
          yi = yi + ((yl - yi) - (((yl - yi) * (@filled / 100)).to_i))
        end

        s = @style.bar || @style
        dattr = sattr s, s.bg, s.fg

        @screen.fill_region dattr, @style.pchar, xi, xl, yi, yl

        if pc = @_pcontent
          line = @screen.lines[yi]
          pc.each_char_with_index do |c, i|
            line[xi + i].char = c
          end
          line.dirty = true
        end

        ret
      end

      def progress(filled)
        f = @filled + filled
        f = 0 if f < 0
        f = 100 if f > 100
        @filled = f
        if @filled == 100
          emit CompleteEvent
        end
        @value = @filled
      end

      def progress=(filled)
        @filled = 0
        progress filled
      end

      def reset
        emit ResetEvent
        @filled = 0
        @value = @filled
      end
    end
  end
end
