module Crysterm
  class Widget
    class ProgressBar < Input
      property filled : Int32 = 0
      property value : Int32 = 0
      property pch : Char = ' '
      property orientation : Tput::Orientation = Tput::Orientation::Horizontal

      # TODO Add new options:
      # replace pch with style.pchar, or even remove pchar in favor of generic property like 'char'
      # min value and max value
      # step of increase
      # does it wrap around?
      # does it print value and/or percentage
      # can it auto-resize based on amount
      # always track of how many % a certain value is
      # Ability to always display filled % or amount

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
          on(Crysterm::Event::KeyPress) do |e|
            # Since the keys aren't conflicting, support both regardless
            # of orientation.
            # case @orientation
            # when Tput::Orientation::Vertical
            #  back_keys = [Tput::Key::Down]
            #  back_chars = ['j']
            #  forward_keys = [Tput::Key::Up]
            #  forward_chars = ['k']
            # else #when Tput::Orientation::Horizontal
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
              screen.render
              next
            elsif forward_keys.includes?(e.key) || forward_chars.includes?(e.char)
              progress 5
              screen.render
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

        # XXX is this insufficient check which shrinks the inner widget on all 4 sides
        # even though border might not be installed on all 4?
        if @border
          xi += 1
          yi += 1
          xl -= 1
          yl -= 1
        end

        if @orientation.horizontal?
          xl = xi + ((xl - xi) * (@filled / 100)).to_i
        else
          yi = yi + ((yl - yi) - (((yl - yi) * (@filled / 100)).to_i))
        end

        # NOTE We invert fg and bg here, so that progressbar's filled value would be
        # rendered using foreground color. This is different than blessed, and:
        # 1) Arguably more correct as far as logic goes
        # 2) And also allows the widget to show filled value in a way which is visible
        #    even if style.bar is not specifically defined
        # Further explanation for (2):
        #   In Blessed, style.bar does not automatically fallback to style. This then causes the
        #     default for bar (filled value) to be black color. If the bg color of the rest is different,
        #     filled value is visible. If it is also black (and it is by default?), then filled
        #     value appears invisible. (And also there is no option to display the percentage as a
        #     number inside the widget.
        #   In Crysterm, style.bar (and all other sub-styles) do fallback to main style. This then
        #     causes the filled value's bg and default bg to always be equal if style.bar is not
        #     specifically defined. And thus it makes filled value show in even less cases than it
        #     does in blessed. By reverting bg/fg like we do here, we solve this problem in a very
        #     elegant way.
        dattr = sattr style.bar, style.bg, style.fg

        # TODO Is this approach with using drawing routines valid, or it would be
        # better that we do this in-memory only here?
        screen.fill_region dattr, style.pchar, xi, xl, yi, yl

        # Why here the formatted content is only in @_pcontent, while in blessed
        # it appears to be in `this.content` directly?
        if (pc = @_pcontent) && !pc.empty?
          screen.lines[yi]?.try do |line|
            pc.each_char_with_index do |c, i|
              line[xi + i]?.try &.char = c
            end
            line.dirty = true
          end
        end

        ret
      end

      def progress(filled)
        f = @filled + filled
        f = 0 if f < 0
        f = 100 if f > 100
        @filled = f
        if f == 100
          emit Crysterm::Event::Complete
        end
        @value = @filled
      end

      def progress=(filled)
        @filled = 0
        progress filled
      end

      def reset
        emit Crysterm::Event::Reset
        @filled = 0
        @value = @filled
      end
    end
  end
end
