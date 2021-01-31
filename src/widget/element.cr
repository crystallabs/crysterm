require "../aux"
require "../events"
require "./node"
require "./element/position"
require "./element/content"
require "./element/pos"
require "./element/rendering"

module Crysterm
  abstract class Element < Node
    include EventHandler
    include Element::Position
    include Element::Content
    include Element::Rendering
    include Element::Pos

    # What action to take when widget would overflow parent's boundaries?
    property overflow = Overflow::Ignore

    # Dock borders? (See `Screen#dock_borders?` for more information)
    property? dock_borders : Bool

    # Draw half-transparent shadow on the element's right and bottom?
    property? shadow : Bool

    # Is element hidden? Hidden elements are not rendered on the screen and their dimensions don't use screen space.
    property? hidden = false

    #
    private property? fixed = false

    # Horizontal text alignment
    property align = AlignFlag::Left

    # Vertical text alignment
    property valign = AlignFlag::Top

    # Can element's content be word-wrapped?
    property? wrap = true

    # Can width/height be auto-adjusted during rendering based on content and child elements?
    property? resizable = false

    # Is element clickable?
    property? clickable = false

    # Can element receive keyboard input?
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    # XXX FIX
    # Used only for lists
    property _isList = false
    property _isLabel = false
    property? interactive = false
    # XXX

    property? auto_focus = false

    property position : Tput::Position

    property? vi : Bool = false

    # XXX why are these here and not in @position?
    #property top = 0
    #property left = 0
    #setter width = 0
    #property height = 0
    def top; _get_top false end
    def left; _get_left false end
    def height; _get_height false end
    def width; _get_width false end

    # Does it accept keyboard input?
    @input = false

    # Is element's content to be parsed for tags?
    property? parse_tags = true

    property? keys : Bool = true
    property? ignore_keys : Bool = false

    # START SCROLLABLE

    # Is element scrollable?
    property? scrollable = false

    property? scrollbar : Bool = false
    property? track : Bool = false

    # Offset from the top of the scroll content.
    property child_base = 0

    property child_offset = 0

    property base_limit = Int32::MAX

    property? always_scroll : Bool = false

    property _scroll_bottom : Int32 = 0

    # END SCROLLABLE

    property? _no_fill = false

    # Amount of padding on the inside of the element
    property padding : Padding

    # Element's border.
    property border : Border?

    def initialize(
      # These end up being part of Position.
      # If position is specified, these are ignored.
      left = nil,
      top = nil,
      right = nil,
      bottom = nil,
      width = nil,
      height = nil,

      hidden = nil,
      @fixed = false,
      @wrap = true,
      @align = AlignFlag::Left,
      @valign = AlignFlag::Top,
      position : Tput::Position? = nil,
      resizable = nil,
      overflow : Overflow? = nil,
      @dock_borders = true,
      @shadow = false,
      style : Style = Style.new, # Previously: Style? = nil
      padding : Padding | Int32 = 0,
      border = nil,
      # @clickable=false,
      content = "",
      label = nil,
      hover_text = nil,
      scrollable = nil,
      # hover_bg=nil,
      @draggable = false,
      focused = false,

      # synonyms
      @parse_tags = true,

      auto_focus = false,

      scrollbar = nil,
      track = nil,

      **node
    )
      resizable.try { |v| @resizable = v }
      hidden.try { |v| @hidden = v }
      scrollable.try { |v| @scrollable = v }
      overflow.try { |v| @overflow = v }

      scrollbar.try { |v| @scrollbar = v }
      track.try { |v| @track = v }

      super **node

      if position
        @position = position
      else
        @position = Tput::Position.new \
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          width: width,
          height: height
      end
      @resizable = true if @position.resizable?

      if style
        @style = style
      else
        @style = Style.new # defaults are in the class initializer
      end

      case padding
      when Int
        @padding = Padding.new padding, padding, padding, padding
      when Padding
        @padding = padding
      else
        raise "Invalid padding argument"
      end

      @border = case border
                when true
                  Border.new BorderType::Line
                when nil
                  # Nothing
                when BorderType
                  Border.new border
                when Border
                  border
                else
                  raise "Invalid border argument"
                end

      set_content(content, true)
      set_label(label) if label
      set_hover(hover_text) if hover_text

      # on(AddHandlerEvent) { |wrapper| }
      on(ResizeEvent) { parse_content }
      on(AttachEvent) { parse_content }
      # on(DetachEvent) { @lpos = nil }

      if @scrollbar
        #@scrollbar.ch ||= ' '
        #@style.scrollbar = @style.scrollbar # || @scrollbar.style
        #if @style.scrollbar.nil?
        #  @style.scrollbar = Style.new
        #  @style.scrollbar.fg = @scrollbar.fg
        #  @style.scrollbar.bg = @scrollbar.bg
        #  @style.scrollbar.bold = @scrollbar.bold
        #  @style.scrollbar.underline = @scrollbar.underline
        #  @style.scrollbar.inverse = @scrollbar.inverse
        #  @style.scrollbar.invisible = @scrollbar.invisible
        #}
        ##@scrollbar.style = @style.scrollbar
        #if (@track) # || @scrollbar.track)
        #  #@track = @scrollbar.track || @track
        #  @style.track = @style.scrollbar.track || @style.track
        #  @track.ch ||= ' '
        #  #@style.track = @style.track || @track.style
        #  #if @style.track.nil?
        #  #  @style.track = Style.new
        #  #  @style.track.fg = @track.fg
        #  #  @style.track.bg = @track.bg
        #  #  @style.track.bold = @track.bold
        #  #  @style.track.underline = @track.underline
        #  #  @style.track.inverse = @track.inverse
        #  #  @style.track.invisible = @track.invisible
        #  #end
        #  #@track.style = @style.track
        #end
        # Allow controlling of the scrollbar via the mouse:
        # TODO
        #if (@mouse)
        #  # TODO
        #end
      end

      ## TODO same as above
      #if @mouse
      #end

      if @keys && !@ignore_keys
        on(KeyPressEvent) do |e|
          key = e.key
          ch = e.char

          if (key == Tput::Key::Up || (@vi && ch == 'k'))
            scroll(-1)
            @screen.render
            next
          end
          if (key == Tput::Key::Down || (@vi && ch == 'j'))
            scroll(1)
            @screen.render
            next
          end

          if @vi
            # XXX remove all those protections for height being Int
            case key
            when Tput::Key::CtrlU
              height.try do |h|
                next unless h.is_a? Int
                offs = -h // 2
                scroll offs == 0 ? -1 : offs
                @screen.render
              end
              next
            when Tput::Key::CtrlD
              height.try do |h|
                next unless h.is_a? Int
                offs = h // 2
                scroll offs == 0 ? 1 : offs
                @screen.render
              end
              next
            when Tput::Key::CtrlB
              height.try do |h|
                next unless h.is_a? Int
                offs = -h
                scroll offs == 0 ? -1 : offs
                @screen.render
              end
              next
            when Tput::Key::CtrlF
              height.try do |h|
                next unless h.is_a? Int
                offs = h
                scroll offs == 0 ? 1 : offs
                @screen.render
              end
              next
            end

            case ch
            when 'g'
              scroll_to 0
              @screen.render
              next
            when 'G'
              scroll_to get_scroll_height
              @screen.render
              next
            end
          end
        end
      end

      if @scrollable
        # XXX also remove handler when scrollable is turned off?
        on(ParsedContentEvent) do
          _recalculate_index
        end

        _recalculate_index
      end

      focus if focused
    end

    # Potentially use this where ever .scrollable? is used
    def really_scrollable?
      return @scrollable if @resizable
      get_scroll_height > height
    end

    def get_scroll
      @child_base + @child_offset
    end

    def scroll_to(offset, always=false)
      scroll 0
      scroll offset - (@child_base + @child_offset), always
    end
    # aka set_scroll

    def _recalculate_index
      return 0 if @detached || !@scrollable

      # D O
      # XXX
      #max = get_scroll_height - (height - iheight)

      max = @_clines.size - (height - iheight)
      max = 0 if max < 0
      emax = @_scroll_bottom - (height - iheight)
      emax = 0 if emax < 0

      @child_base = Math.min @child_base, Math.max emax, max 

      if @child_base < 0
        @child_base = 0
      elsif @child_base > @base_limit
        @child_base = @base_limit
      end
    end

    def get_scroll_height
      Math.max @_clines.size, @_scroll_bottom
    end

    def set_scroll_perc(i)
      # D O
      # XXX
      # m = @get_scroll_height
      m = Math.max @_clines.size, @_scroll_bottom
      scroll_to ((i / 100) * m).to_i
    end

    def reset_scroll
      return unless @scrollable
      @child_offset = 0
      @child_base = 0
      return emit ScrollEvent
    end

    def get_scroll_perc(s)
      pos = @lpos || @_get_coords
      if !pos
        return s ? -1 : 0
      end

      height = (pos.yl - pos.yi) - iheight
      i = get_scroll_height
      #p

      if (height < i)
        if @always_scroll
          p = @child_base / (i - height)
        else
          p = (@child_base + @child_offset) / (i - 1)
        end
        return p * 100
      end

      return s ? -1 : 0
    end

    def _scroll_bottom
      return 0 unless @scrollable

      # We could just calculate the children, but we can
      # optimize for lists by just returning the items.length.
      # XXX _isList!
      if @_isList
        return @items ? @items.size : 0
      end

      @lpos.try do |lpos|
        if lpos._scroll_bottom != 0
          return lpos._scroll_bottom
        end
      end

      bottom = @children.reduce(0) do |current, el|
        # el.height alone does not calculate the shrunken height, we need to use
        # get_coords. A shrunken box inside a scrollable element will not grow any
        # larger than the scrollable element's context regardless of how much
        # content is in the shrunken box, unless we do this (call get_coords
        # without the scrollable calculation):
        # See: $ test/widget-shrink-fail-2
        if !el.detached?
          lpos = el._get_coords false, true
          if lpos
            return Math.max(current, el.rtop + (lpos.yl - lpos.yi))
          end
        end
        return Math.max(current, el.rtop + el.height)
      end

      # XXX Use this? Makes .get_scroll_height useless
      # if bottom < @_clines.size
      #   bottom = @_clines.size
      # end

      @lpos.try do |lpos|
        lpos._scroll_bottom = bottom
      end

      bottom
    end

    def scroll(offset, always=false)
      return unless @scrollable
      return if @detached

      # Handle scrolling.
      visible = height - iheight
      base = @child_base

      if (@always_scroll || always)
        # Semi-workaround
        @child_offset = offset > 0 ? visible - 1 + offset : offset
      else
        @child_offset += offset
      end

      if (@child_offset > visible - 1)
        d = @child_offset - (visible - 1)
        @child_offset -= d
        @child_base += d
      elsif (@child_offset < 0)
        d = @child_offset
        @child_offset += -d
        @child_base += d
      end

      if (@child_base < 0)
        @child_base = 0
      elsif (@child_base > @base_limit)
        @child_base = @base_limit
      end

      # Find max "bottom" value for
      # content and descendant elements.
      # Scroll the content if necessary.
      if (@child_base == base)
        return emit ScrollEvent
      end

      # When scrolling text, we want to be able to handle SGR codes as well as line
      # feeds. This allows us to take preformatted text output from other programs
      # and put it in a scrollable text box.
      parse_content

      # D O:
      # XXX
      # max = get_scroll_height - (height - iheight)

      max = @_clines.size - (height - iheight)
      if (max < 0)
        max = 0
      end
      emax = _scroll_bottom - (height - iheight)
      if (emax < 0)
        emax = 0
      end

      @child_base = Math.min @child_base, Math.max(emax, max)

      if (@child_base < 0)
        @child_base = 0
      elsif (@child_base > @base_limit)
        @child_base = @base_limit
      end

      # Optimize scrolling with CSR + IL/DL.
      p = @lpos
      # Only really need _getCoords() if we want
      # to allow nestable scrolling elements...
      # or if we **really** want shrinkable
      # scrolling elements.
      # p = @_get_coords
      if (p && @child_base != base && @screen.clean_sides(self))
        t = p.yi + itop
        b = p.yl - ibottom - 1
        d = @child_base - base

        if (d > 0 && d < visible)
          # scrolled down
          @screen.delete_line(d, t, t, b)
        elsif (d < 0 && -d < visible)
          # scrolled up
          d = -d
          @screen.insert_line(d, t, t, b)
        end
      end

      emit ScrollEvent
    end

    def set_label(label)
    end

    def remove_label
    end

    def set_hover(hover_text)
    end

    def remove_hover
    end

    def hide
      return if @hidden
      clear_pos
      @hidden = true
      emit HideEvent
      # @screen.rewind_focus if focused?
      @screen.rewind_focus if @screen.focused == self
    end

    def show
      return unless @hidden
      @hidden = false
      emit ShowEvent
    end

    def toggle_visibility
      @hidden ? show : hide
    end

    def focus
      # XXX Prevents getting multiple `FocusEvent`s. Remains to be
      # seen whether that's good, or it should always happen, even
      # if someone calls `#focus` multiple times in a row.
      return if focused?
      @screen.focused = self
    end

    def focused?
      @screen.focused == self
    end

    def visible?
      el = self
      while el
        return false if el.detached?
        return false if el.hidden?
        el = el.parent
      end
      true
    end

    def _detached?
      el = self
      while el
        return false if el.is_a? Screen
        return true if !el.parent
        el = el.parent
      end
      false
    end

    def draggable?
      @_draggable
    end

    def draggable=(draggable : Bool)
      draggable ? enable_drag(draggable) : disable_drag
    end

    def enable_drag(x)
      @_draggable = true
    end

    def disable_drag
      @_draggable = false
    end

    def set_index(index)
      return unless parent = @parent
      if index < 0
        index = parent.children.size + index
      end

      index = Math.max index, 0
      index = Math.min index, parent.children.size - 1

      i = parent.children.index self
      return unless i

      parent.children.insert index, parent.children.delete_at i
      nil
    end

    def front!
      set_index -1
    end

    def back!
      set_index 0
    end

    def self.sattr(style, fg = nil, bg = nil)
      # See why this can be nil
      # XXX Don't insert default this crude.
      style = style || Style.new

      if fg.nil? && bg.nil?
        fg = style.try &.fg
        bg = style.try &.bg
      end

      # Support style.* being Procs

      ((style.invisible ? 16 : 0) << 18) |
        ((style.inverse ? 8 : 0) << 18) |
        ((style.blink ? 4 : 0) << 18) |
        ((style.underline ? 2 : 0) << 18) |
        ((style.bold ? 1 : 0) << 18) |
        (Colors.convert(fg) << 9) |
        Colors.convert(bg)
    end

    def sattr(style, fg = nil, bg = nil)
      self.class.sattr style, fg, bg
    end

    def free
      # Remove all listeners
    end

    def screenshot(xi = nil, xl = nil, yi = nil, yl = nil)
      xi = @lpos.xi + ileft + (xi || 0)
      if xl
        xl = @lpos.xi + ileft + (xl || 0)
      else
        xl = @lpos.xl - iright
      end

      yi = @lpos.yi + itop + (yi || 0)
      if yl
        yl = @lpos.yi + itop + (yl || 0)
      else
        yl = @lpos.yl - ibottom
      end

      @screen.screenshot xi, xl, yi, yl
    end

    def _update_cursor(arg)
    end
  end
end
