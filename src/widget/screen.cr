require "./node"
require "../application"
require "./screen/*"

module Crysterm
  class BorderStop
    property? yes = false
    property xi : Int32?
    property xl : Int32?
  end
  class BorderStops < Hash(Int32, BorderStop)
    def []=(idx : Int32, arg)
      self[idx]? || (self[idx] = BorderStop.new)
      case arg
      when Bool
        self[idx].yes = arg
      else
        self[idx].xi = arg.xi
        self[idx].xl = arg.xl
      end
    end
  end

  # Represents a screen. `Screen` and `Element` are two lowest-level classes after `EventEmitter` and `Node`.
  class Screen < Node
    include Screen::Focus
    include Element::Pos

    @angles = {
      '\u2518' => true, # '┘'
      '\u2510' => true, # '┐'
      '\u250c' => true, # '┌'
      '\u2514' => true, # '└'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2524' => true, # '┤'
      '\u2534' => true, # '┴'
      '\u252c' => true, # '┬'
      '\u2502' => true, # '│'
      '\u2500' => true  # '─'
    }

    @langles = {
      '\u250c' => true, # '┌'
      '\u2514' => true, # '└'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2534' => true, # '┴'
      '\u252c' => true, # '┬'
      '\u2500' => true  # '─'
    }

    @uangles = {
      '\u2510' => true, # '┐'
      '\u250c' => true, # '┌'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2524' => true, # '┤'
      '\u252c' => true, # '┬'
      '\u2502' => true  # '│'
    }

    @rangles = {
      '\u2518' => true, # '┘'
      '\u2510' => true, # '┐'
      '\u253c' => true, # '┼'
      '\u2524' => true, # '┤'
      '\u2534' => true, # '┴'
      '\u252c' => true, # '┬'
      '\u2500' => true  # '─'
    }

    @dangles = {
      '\u2518' => true, # '┘'
      '\u2514' => true, # '└'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2524' => true, # '┤'
      '\u2534' => true, # '┴'
      '\u2502' => true  # '│'
    }

    # Every ACS angle character can be
    # represented by 4 bits ordered like this:
    # [langle][uangle][rangle][dangle]
    @angle_table = {
      0 => ' ', # ?               "0000"
      1 => '\u2502', # '│' # ?   '0001'
      2 => '\u2500', # '─' # ??  '0010'
      3 => '\u250c', # '┌'       '0011'
      4 => '\u2502', # '│' # ?   '0100'
      5 => '\u2502', # '│'       '0101'
      6 => '\u2514', # '└'       '0110'
      7 => '\u251c', # '├'       '0111'
      8 => '\u2500', # '─' # ??  '1000'
      9 => '\u2510', # '┐'       '1001'
     10 => '\u2500', # '─' # ??  '1010'
     11 => '\u252c', # '┬'       '1011'
     12 => '\u2518', # '┘'       '1100'
     13 => '\u2524', # '┤'       '1101'
     14 => '\u2534', # '┴'       '1110'
     15 => '\u253c'  # '┼'       '1111'
    }

    @ignore_dock_contrast = false

    @use_bce = false

    macro put(arg)
      application.tput.shim.try { |s| {{arg}}.try { |data| application.tput._write data }}
    end

    class_getter instances = [] of self
    def self.total
      @@instances.size
    end
    def self.global
      instances[0]?.not_nil!
    end

    property! application : Application
    property focused : Element?
    property _saved_focus : Element?

    getter! tabc : String

    property dattr : Int32 = ((0 << 18) | (0x1ff << 9)) | 0x1ff

    property padding = Padding.new

    getter title : String?

    #@hover = nil
    #@history = [] of
    @clickable = [] of Node
    @keyable = [] of Node
    property grab_keys = false
    property lock_keys = false
    @_buf = ""
    property _ci = -1

    getter cursor = Cursor.new

    @_border_stops = BorderStops.new

    class Cell
      # Same as @dattr
      property attr : Int32 = ((0 << 18) | (0x1ff << 9)) | 0x1ff
      property char : Char = ' '
      def initialize(@attr, @char)
      end
      def initialize(@char)
      end
      def initialize
      end
    end

    class Row < Array(Cell)
      property dirty = false
    end

    property lines = Array(Row).new
    property olines = Array(Row).new

    property auto_padding = true

    property top=0
    property left=0
    property width=0
    property height=0

    property? dock_borders
    property _border_stops = {} of Int32 => Bool

    def initialize(
      application = nil,
      @auto_padding = true,
      @tab_size = 4,
      @dock_borders = false,
      @ignore_locked = [] of Element, # or Node
      @title = nil,
    )
      bind

      @application = application ||= Application.new
      #ensure tput.zero_based = true, use_bufer=true
      # set resizeTimeout

      # Tput is accessed via application.tput

      super()

      @tabc = " " * @tab_size

      # _unicode is application.tput.features.unicode?
      # todo: wth full_unicode?

      @cursor = Cursor.new

      # Events:
      # addhander,



      application.on(ResizeEvent) do
        alloc
        render

        # TODO replace all places using uninitialized directly with
        # a call to for_descendants { block } or similar
        f = uninitialized Node -> Nil
        f = ->(el : Node) {
          el.emit ResizeEvent
          el.children.each do |c| f.call c end
        }
        f.call self
      end

      application.on(FocusEvent) do
        emit FocusEvent
      end
      application.on(BlurEvent) do
        emit BlurEvent
      end
      application.on(WarningEvent) do |e|
        emit WarningEvent.new e.message
      end

      @renders = 0

      application.on(FocusEvent) {
        emit FocusEvent
      }

      application.on(BlurEvent) {
        emit BlurEvent
      }

      _listen_keys

      enter
      post_enter
    end

    def _listen_keys
      application.on(KeyPressEvent) do |e|
        el = @focused || self
        while !e.accepted? && el
          # XXX emit only if widget enabled?
          el.emit e
          el = el.parent
        end
      end
    end

    #def _listen_keys(el)
    #  if (el && !~this.keyable.indexOf(el))
    #    el.keyable = true
    #    this.keyable.push(el)
    #  end

    #  if (this._listenedKeys) return
    #  this._listenedKeys = true

    #  # NOTE: The event emissions used to be reversed:
    #  # element + screen
    #  # They are now:
    #  # screen + element
    #  # After the first keypress emitted, the handler
    #  # checks to make sure grabKeys, lockKeys, and focused
    #  # weren't changed, and handles those situations appropriately.
    #  this.program.on('keypress', function(ch, key)
    #    if (@lockKeys && !~@ignoreLocked.indexOf(key.full))
    #      return
    #    end

    #    var focused = @focused
    #      , grabKeys = @grabKeys

    #    if (!grabKeys || ~@ignoreLocked.indexOf(key.full))
    #      @emit('keypress', ch, key)
    #      @emit('key ' + key.full, ch, key)
    #    end

    #    # If something changed from the screen key handler, stop.
    #    if (@grabKeys !== grabKeys || @lockKeys)
    #      return
    #    end

    #    if (focused && focused.keyable)
    #      focused.emit('keypress', ch, key)
    #      focused.emit('key ' + key.full, ch, key)
    #    end
    #  })
    #end

    #def enable_keys(el)
    #  _listen_keys(el)
    #end

    #def enable_input(el)
    #  _listen_mouse(el)
    #  _listen_keys(el)
    #end

    def bind
      @@global = self unless @@global

      @@instances << self #unless @@instances.includes? self

      return if @@_bound
      @@_bound = true

      # TODO Enable
      #['SIGTERM', 'SIGINT', 'SIGQUIT'].forEach(function(signal) {
      #  var name = '_' + signal.toLowerCase() + 'Handler';
      #  process.on(signal, Screen[name]() {
      #    if (process.listeners(signal).length > 1) {
      #      return;
      #    }
      #    nextTick(function() {
      #      process.exit(0);
      #    });
      #  });
      #});

      at_exit {
        Crysterm::Screen.instances.each do |screen|
          screen.destroy
        end
      }
    end

    def enter
      # TODO make it possible to work without switching the whole
      # application to alt buffer.
      return if application.tput.is_alt

      if !cursor._set
        if cursor.shape
          cursor_shape cursor.shape, cursor.blink
        end
        if cursor.color
          cursor_color cursor.color
        end
      end

      # XXX
      {% if flag? :windows %}
        `cls`
      {% end %}

      application.tput.alternate_buffer
      put(s.keypad_xmit?) # enter_keyboard_transmit_mode
      put(s.change_scroll_region?(0, application.tput.screen.height-1))
      application.tput.hide_cursor
      application.tput.cursor_pos 0, 0
      put(s.ena_acs?) # enable_acs

      alloc
    end

    def alloc(dirty=false)
      rows = application.tput.screen.height
      cols = application.tput.screen.width

      # Initialize @lines better than this.
      rows.times do |i|
        col = Row.new
        cols.times do
          col.push Cell.new
        end
        @lines.push col
        @lines[-1].dirty = dirty
      end

      # Initialize @lines better than this.
      rows.times do |i|
        col = Row.new
        cols.times do
          col.push Cell.new
        end
        @olines.push col
        @olines[-1].dirty = dirty
      end

      application.tput.clear
    end

    def realloc
      alloc dirty: true
    end

    def leave
      # TODO make it possible to work without switching the whole
      # application to alt buffer.
      return unless application.tput.is_alt

      put(s.keypad_local?)

      if( (application.tput.scroll_top != 0) ||
          application.tput.scroll_bottom != application.tput.screen.height - 1)
        application.tput.csr(0, application.tput.screen.height - 1)
      end

      # XXX For some reason if alloc/clear() is before this
      # line, it doesn't work on linux console.
      application.tput.show_cursor
      alloc

      # TODO Enable all in this function
      #if (this._listened_mouse)
      #  application.disable_mouse
      #end

      application.tput.normal_buffer
      if cursor._set
        application.tput.cursor_reset
      end

      application.tput.flush

      {% if flag? :windows %}
        `cls`
      {% end %}
    end

    def destroy
      leave
      if @@instances.delete self
        if @@instances.any?
          @@global = @@instances[0]
        else
          @@global = nil
          # TODO remove all signal handlers set up on the app's process
          @@_bound = false
        end

        @destroyed = true
        emit DestroyEvent

        super
      end

      application.destroy
    end

    # Debug
    def post_enter
    end

    # XXX Crutch. Remove when everything's in place.
    def cols; application.tput.screen.width end
    def rows; application.tput.screen.height end
    def width; cols end
    def height; rows end

    def cursor_shape(shape : CursorShape = CursorShape::Block, blink : Bool = false)
      @cursor.shape = shape
      @cursor.blink = blink
      @cursor._set = true

      if @cursor.artificial
        raise "Not supported yet"
        #if !application.hide_cursor_old
        #  hide_cursor = application.hide_cursor
        #  application.tput.hide_cursor_old = application.hide_cursor
        #  application.tput.hide_cursor = ->{
        #    hide_cursor.call(application)
        #    @cursor._hidden = true
        #    if (@renders > 0)
        #      render
        #    end
        #  }
        #end
        #if (!application.showCursor_old)
        #  var showCursor = application.showCursor
        #  application.showCursor_old = application.showCursor
        #  application.showCursor = function()
        #    self.cursor._hidden = false
        #    if (application._exiting) showCursor.call(application)
        #    if (self.renders) self.render()
        #  }
        #end
        #if (!@_cursorBlink)
        #  @_cursorBlink = setInterval(function()
        #    if (!self.cursor.blink) return
        #    self.cursor._state ^= 1
        #    if (self.renders) self.render()
        #  }, 500)
        #  if (@_cursorBlink.unref)
        #    @_cursorBlink.unref()
        #  end
        #end
        return true
      end

      application.tput.cursor_shape(@cursor.shape, @cursor.blink)
    end
    def cursor_color(color : Tput::Color? = nil)
      @cursor.color = color.try do |c|
        Tput::Color.new Colors.convert(c.value)
      end
      @cursor._set = true

      if (@cursor.artificial)
        return true
      end

      # XXX probably this isn't fully right
      application.tput.cursor_color(@cursor.color.to_s.downcase)
    end

    def render
      return if destroyed?

      emit PreRenderEvent

      @_border_stops.clear

      # TODO: Possibly get rid of .dirty altogether.
      # TODO: Could possibly drop .dirty and just clear the `lines` buffer every
      # time before a screen.render. This way clearRegion doesn't have to be
      # called in arbitrary places for the sake of clearing a spot where an
      # element used to be (e.g. when an element moves or is hidden). There could
      # be some overhead though.
      # screen.clearRegion(0, this.cols, 0, this.rows);
      @_ci = 0
      @children.each do |el|
        el.index = @_ci
        @_ci += 1
        #el._rendering = true;
        el.render
        #el._rendering = false;
      end
      @_ci = -1;

      if (@screen.dock_borders?)
        _dock_borders
      end

      draw 0, @lines.size - 1

      # Workaround to deal with cursor pos before the screen
      # has rendered and lpos is not reliable (stale).
      # Only some element have this functions; for others it's a noop.
      @focused.try &._update_cursor(true)

      @renders+=1

      emit RenderEvent
    end

    def draw(start=0, stop=@lines.size-1)
      # D O:
      # this.emit('predraw');
      #x , y , line , out , ch , data , attr , fg , bg , flags
      #pre , post
      #clr , neq , xx
      #acs
      main = ""
      lx = -1
      ly = -1
      acs = false
      s = application.tput.shim.not_nil!

      if @_buf
        main += @_buf
        @_buf = ""
      end

      Log.trace { "Drawing #{start}..#{stop}" }

      (start..stop).each do |y|
        line = @lines[y]
        o = @olines[y]
        #Log.trace { line } if line.any? &.char.!=(' ')

        if (!line.dirty && !(cursor.artificial && (y == application.y)))
          next
        end
        line.dirty = false

        # Assume line is dirty by continuing: (XXX need to optimize)

        outbuf = ""
        attr = @dattr

        line.size.times do |x|
          data = line[x].attr
          ch = line[x].char

          c = cursor
          # Render the artificial cursor.
          if (c.artificial && !c._hidden && (c._state!=0) && (x == application.x) && (y == application.y))
            cattr = _cursor_attr(c, data)
            if (cattr.char)
              ch = cattr.char
            end
            data = cattr.attr
          end

          # Take advantage of xterm's back_color_erase feature by using a
          # lookahead. Stop spitting out so many damn spaces. NOTE: Is checking
          # the bg for non BCE terminals worth the overhead?
          if (@use_bce &&
              ch == ' ' &&
              (application.tput.terminfo.try &.get(Unibilium::Entry::Boolean::Back_color_erase) || (data & 0x1ff) == (@dattr & 0x1ff)) &&
              (((data >> 18) & 8) == ((@dattr >> 18) & 8)))

            clr = true
            neq = false

            (x...line.size).each do |xx|
              if (line[xx].attr != data || line[xx].char != ' ')
                clr = false
                break
              end
              if (line[xx].attr != o[xx].attr || line[xx].char != o[xx].char)
                neq = true
              end
            end

            if (clr && neq)
              lx = -1
              ly = -1
              if (data != attr)
                outbuf += code_attr(data)
                attr = data
              end
              #######################
              # XXX BAD HAQ
              temp = IO::Memory.new
              old = application.output
              application.output = temp
              application.tput.cup(y, x)
              application.tput.el
              outbuf += temp.gets_to_end
              application.output = old
              #######################
              (x...line.size).each do |xx|
                o[xx].attr = data
                o[xx].char = ' '
              end
              break
            end

            # Disabled originally:
            #// If there's more than 10 spaces, use EL regardless
            #// and start over drawing the rest of line. Might
            #// not be worth it. Try to use ECH if the terminal
            #// supports it. Maybe only try to use ECH here.
            #// #//if (application.tput.strings.erase_chars)
            #// if (!clr && neq && (xx - x) > 10) {
            #//   lx = -1, ly = -1;
            #//   if (data != attr) {
            #//     outbuf += @codeAttr(data);
            #//     attr = data;
            #//   }
            #//   outbuf += application.tput.cup(y, x);
            #//   if (application.tput.strings.erase_chars) {
            #//     #// Use erase_chars to avoid erasing the whole line.
            #//     outbuf += application.tput.ech(xx - x);
            #//   } else {
            #//     outbuf += application.tput.el();
            #//   }
            #//   if (application.tput.strings.parm_right_cursor) {
            #//     outbuf += application.tput.cuf(xx - x);
            #//   } else {
            #//     outbuf += application.tput.cup(y, xx);
            #//   }
            #//   @fillRegion(data, ' ',
            #//     x, application.tput.strings.erase_chars ? xx : line.length,
            #//     y, y + 1);
            #//   x = xx - 1;
            #//   continue;
            #// }
            #// Skip to the next line if the
            #// rest of the line is already drawn.
            #// if (!neq) {
            #//   for (; xx < line.length; xx++) {
            #//     if (line[xx][0] != o[xx][0] || line[xx][1] != o[xx][1]) {
            #//       neq = true;
            #//       break;
            #//     }
            #//   }
            #//   if (!neq) {
            #//     attr = data;
            #//     break;
            #//   }
            #// }
          end

          # Optimize by comparing the real output
          # buffer to the pending output buffer.
          # TODO Avoid using Strings
          if (data == o[x].attr && ch == o[x].char)
            if (lx == -1)
              lx = x
              ly = y
            end
            next
          elsif (lx != -1)
            if (s.parm_right_cursor?)
              outbuf += String.new ((y == ly) ? s.cuf(x - lx) : s.cup(y, x))
            else
              outbuf += String.new s.cup(y, x)
            end
            lx = -1
            ly = -1
          end
          o[x].attr = data
          o[x].char = ch

          if (data != attr)
            if (attr != @dattr)
              outbuf += "\x1b[m";
            end
            if (data != @dattr)
              outbuf += "\x1b["

              bg = data & 0x1ff;
              fg = (data >> 9) & 0x1ff;
              flags = data >> 18;

              # bold
              if ((flags & 1) != 0)
                outbuf += "1;";
              end

              # underline
              if ((flags & 2) != 0)
                outbuf += "4;";
              end

              # blink
              if ((flags & 4) != 0)
                outbuf += "5;";
              end

              # inverse
              if ((flags & 8) != 0)
                outbuf += "7;";
              end

              # invisible
              if ((flags & 16) != 0)
                outbuf += "8;";
              end

              if (bg != 0x1ff)
                bg = _reduce_color(bg);
                if (bg < 16)
                  if (bg < 8)
                    bg += 40;
                  elsif (bg < 16)
                    bg -= 8;
                    bg += 100;
                  end
                  outbuf += "#{bg};";
                else
                  outbuf += "48;5;#{bg};";
                end
              end

              if (fg != 0x1ff)
                fg = _reduce_color(fg);
                if (fg < 16)
                  if (fg < 8)
                    fg += 30;
                  elsif (fg < 16)
                    fg -= 8;
                    fg += 90;
                  end
                  outbuf += "#{fg};"
                else
                  outbuf += "38;5;#{fg};"
                end
              end

              if (outbuf[-1] == ';')
                outbuf = outbuf[...-1]
              end

              outbuf += 'm'
              Log.trace { outbuf.inspect }
            end
          end

          # TODO Enable this
          ## If we find a double-width char, eat the next character which should be
          ## a space due to parseContent's behavior.
          #if (@fullUnicode)
          #  # If this is a surrogate pair double-width char, we can ignore it
          #  # because parseContent already counted it as length=2.
          #  if (unicode.charWidth(line[x].char) == 2)
          #    # NOTE: At cols=44, the bug that is avoided
          #    # by the angles check occurs in widget-unicode:
          #    # Might also need: `line[x + 1].attr != line[x].attr`
          #    # for borderless boxes?
          #    if (x == line.length - 1 || angles[line[x + 1].char])
          #      # If we're at the end, we don't have enough space for a
          #      # double-width. Overwrite it with a space and ignore.
          #      ch = ' '
          #      o[x].char = '\0'
          #    else
          #      # ALWAYS refresh double-width chars because this special cursor
          #      # behavior is needed. There may be a more efficient way of doing
          #      # @ See above.
          #      o[x].char = '\0'
          #      # Eat the next character by moving forward and marking as a
          #      # space (which it is).
          #      o[++x].char = '\0'
          #    end
          #  end
          #end

          # Attempt to use ACS for supported characters.
          # This is not ideal, but it's how ncurses works.
          # There are a lot of terminals that support ACS
          # *and UTF8, but do not declare U8. So ACS ends
          # up being used (slower than utf8). Terminals
          # that do not support ACS and do not explicitly
          # support UTF8 get their unicode characters
          # replaced with really ugly ascii characters.
          # It is possible there is a terminal out there
          # somewhere that does not support ACS, but
          # supports UTF8, but I imagine it's unlikely.
          # Maybe remove !application.tput.unicode check, however,
          # this seems to be the way ncurses does it.
          if s
            if (s.enter_alt_charset_mode? && !application.tput.features.broken_acs? && (application.tput.features.acscr[ch]? || acs))
              # Fun fact: even if application.tput.brokenACS wasn't checked here,
              # the linux console would still work fine because the acs
              # table would fail the check of: application.tput.features.acscr[ch]
              # TODO This is nasty. Char gets changed to string
              # when sm/rm is added to the stream.
              if (application.tput.features.acscr[ch]?)
                if (acs)
                  ch = application.tput.features.acscr[ch]
                else
                  sm = String.new s.smacs
                  ch = sm + application.tput.features.acscr[ch]
                  acs = true
                end
              elsif acs
                rm = String.new s.rmacs
                ch = rm + ch
                acs = false
              end
            end
          else
            # U8 is not consistently correct. Some terminfo's
            # terminals that do not declare it may actually
            # support utf8 (e.g. urxvt), but if the terminal
            # does not declare support for ACS (and U8), chances
            # are it does not support UTF8. This is probably
            # the "safest" way to do @ Should fix things
            # like sun-color.
            # NOTE: It could be the case that the $LANG
            # is all that matters in some cases:
            # if (!application.tput.unicode && ch > '~') {
            if (!application.tput.features.unicode? && ( application.tput.terminfo.try(&.extensions.get_num?("U8")) != 1) && (ch > '~'))
              # TODO
              #ch = Tput::Data::UtoA[ch]? || '?';
              ch = '?'
            end
          end

          outbuf += ch
          attr = data
        end

        if (attr != @dattr)
          outbuf += "\x1b[m"
        end

        unless outbuf.empty?
          # TODO, again remove strings use
          main += String.new(s.cup(y, 0).to_slice) + outbuf
        end
      end

      if (acs)
        main += String.new s.rmacs
        acs = false
      end

      unless main.empty?
        pre = ""
        post = ""

        # TODO This unconditionally calls methods. Do they exist?
        pre += String.new s.sc
        post += String.new s.rc
        if !application.cursor_hidden
          pre += String.new s.civis
          post += String.new s.cnorm
        end

        # D O:
        # application.flush()
        # application._owrite(pre + main + post)
        application.tput._print(pre + main + post)
      end

      # D O:
      #emit DrawEvent
    end

    # Convert our own attribute format to an SGR string.
    def code_attr(code)
      flags = (code >> 18) & 0x1ff
      fg = (code >> 9) & 0x1ff
      bg = code & 0x1ff
      outbuf = ""

      # bold
      if ((flags & 1) != 0)
        outbuf += "1;"
      end

      # underline
      if ((flags & 2) != 0)
        outbuf += "4;"
      end

      # blink
      if ((flags & 4) != 0)
        outbuf += "5;"
      end

      # inverse
      if ((flags & 8) != 0)
        outbuf += "7;"
      end

      # invisible
      if ((flags & 16) != 0)
        outbuf += "8;"
      end

      if (bg != 0x1ff)
        bg = _reduce_color(bg)
        if (bg < 16)
          if (bg < 8)
            bg += 40
          elsif (bg < 16)
            bg -= 8
            bg += 100
          end
          outbuf += "#{bg};"
        else
          outbuf += "48;5;#{bg};"
        end
      end

      if (fg != 0x1ff)
        fg = _reduce_color(fg)
        if (fg < 16)
          if (fg < 8)
            fg += 30
          elsif (fg < 16)
            fg -= 8
            fg += 90
          end
          outbuf += "#{fg};"
        else
          outbuf += "38;5;#{fg};"
        end
      end

      if (outbuf[-1] == ";")
        outbuf = outbuf[0..-2]
      end

      "\x1b[#{outbuf}m"
    end

    def cursor_reset
      @cursor.shape = CursorShape::Block
      @cursor.blink = false
      @cursor.color = nil
      @cursor._set = false

      # TODO if artificial cursor

      application.tput.cursor_reset
    end
    alias_previous reset_cursor

    def _cursor_attr(cursor, dattr=nil)
      attr = dattr || @dattr
      #cattr
      #ch
      if (cursor.shape == CursorShape::Line)
        attr &= ~(0x1ff << 9)
        attr |= 7 << 9
        ch = '\u2502'
      elsif (cursor.shape == CursorShape::Underline)
        attr &= ~(0x1ff << 9)
        attr |= 7 << 9
        attr |= 2 << 18
      elsif (cursor.shape == CursorShape::Block)
        attr &= ~(0x1ff << 9)
        attr |= 7 << 9
        attr |= 8 << 18
      elsif (cursor.shape)
        #cattr = Element.sattr(cursor, cursor.shape)
        #if (cursor.shape.bold || cursor.shape.underline ||
        #    cursor.shape.blink || cursor.shape.inverse ||
        #    cursor.shape.invisible)
        #  attr &= ~(0x1ff << 18)
        #  attr |= ((cattr >> 18) & 0x1ff) << 18
        #end
        #if (cursor.shape.fg)
        #  attr &= ~(0x1ff << 9)
        #  attr |= ((cattr >> 9) & 0x1ff) << 9
        #end
        #if (cursor.shape.bg)
        #  attr &= ~(0x1ff << 0)
        #  attr |= cattr & 0x1ff
        #end
        #if (cursor.shape.ch)
        #  ch = cursor.shape.ch
        #end
      end

      unless (cursor.color.nil?)
        attr &= ~(0x1ff << 9)
        attr |= cursor.color.value << 9
      end

      return Cell.new \
        attr: attr,
        char: ch || ' '

    end

    def _reduce_color(col)
      Colors.reduce(col, application.tput.features.number_of_colors)
    end

    def clear_region(xi, xl, yi, yl, override)
      fill_region @dattr, ' ', xi, xl, yi, yl, override
    end

    def fill_region(attr, ch, xi, xl, yi, yl, override=false)
      lines = @lines

      if (xi < 0)
        xi = 0
      end
      if (yi < 0)
        yi = 0
      end

      while yi < yl
        break unless @lines[yi]?

        xx = xi
        while xx < xl
          cell = lines[yi][xx]?
          break unless cell

          if (override || (attr != cell.attr) || (ch != cell.char))
            lines[yi][xx].attr = attr
            lines[yi][xx].char = ch
            lines[yi].dirty = true;
          end

          xx += 1
        end
        yi += 1
      end
    end

    def _dock_borders
    end

    def blank_line(ch, dirty)
      o = Row.new cols, [@dattr, ch]
      o.dirty = dirty
      o
    end

    def insert_line(n, y, top, bottom)
      # D O:
      # if (y == top)
      #  return insert_line_nc(n, y, top, bottom)
      # end

      if (!application.tput.has?(change_scroll_region) ||
          !application.tput.has?(delete_line) ||
          !application.tput.has?(insert_line))
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      @_buf += application.tput.csr(top, bottom)
      @_buf += application.tput.cup(y, 0)
      @_buf += application.tput.il(n)
      @_buf += application.tput.csr(0, height - 1)

      j = bottom + 1

      n.times do
        @lines.insert y, blank_line
        @lines.delete_at j
        @olines.insert y, blank_line
        @olines.delete_at j
      end
    end

    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    def insert_line_nc(n, y, top, bottom)
      if (!application.tput.has?(change_scroll_region) ||
          !application.tput.has?(delete_line))
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      @_buf += application.tput.csr(top, bottom)
      @_buf += application.tput.cup(top, 0)
      @_buf += application.tput.dl(n)
      @_buf += application.tput.csr(0, height - 1)

      j = bottom + 1

      n.times do
        @lines.insert y, blank_line
        @lines.delete_at j
        @olines.insert y, blank_line
        @olines.delete_at j
      end
    end

    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    def delete_line_nc(n, y, top, bottom)
      if (!application.tput.has?(change_scroll_region) ||
          !application.tput.has?(delete_line))
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      @_buf += application.tput.csr(top, bottom)
      @_buf += application.tput.cup(bottom, 0)
      @_buf += "\n" * n
      @_buf += application.tput.csr(0, height - 1)

      j = bottom + 1

      n.times do
        @lines.insert j, blank_line
        @lines.delete_at y
        @olines.insert j, blank_line
        @olines.delete_at y
      end
    end

    def insert_bottom(top, bottom)
      delete_line(1, top, top, bottom)
    end

    def insert_top(top, bottom)
      insert_line(1, top, top, bottom)
    end

    def delete_bottom(top, bottom)
      clear_region(0, width, bottom, bottom)
    end

    def delete_top(top, bottom)
      # Same as: insert_bottom(top, bottom)
      delete_line(1, top, top, bottom)
    end

    # Parse the sides of an element to determine
    # whether an element has uniform cells on
    # both sides. If it does, we can use CSR to
    # optimize scrolling on a scrollable element.
    # Not exactly sure how worthwile this is.
    # This will cause a performance/cpu-usage hit,
    # but will it be less or greater than the
    # performance hit of slow-rendering scrollable
    # boxes with clean sides?
    def clean_sides(el)
      pos = el.lpos

      if (!pos)
        return false
      end

      unless (pos._clean_sides.nil?)
        return pos._clean_sides
      end

      if (pos.xi <= 0 && (pos.xl >= width))
        return pos._clean_sides = true
      end

      if (@fast_csr)
        # Maybe just do this instead of parsing.
        if (pos.yi < 0)
          return pos._clean_sides = false
        end
        if (pos.yl > height)
          return pos._clean_sides = false
        end
        if ((width - (pos.xl - pos.xi)) < 40)
          return pos._clean_sides = true
        end
        return pos._clean_sides = false
      end

      if (!@smart_csr)
        return false
      end

      # D O:
      # The scrollbar can't update properly, and there's also a
      # chance that the scrollbar may get moved around senselessly.
      # NOTE: In pratice, this doesn't seem to be the case.
      #if (@scrollbar)
      #  return pos._clean_sides = false
      #end
      # Doesn't matter if we're only a height of 1.
      # if ((pos.yl - el.ibottom) - (pos.yi + el.itop) <= 1)
      #   return pos._clean_sides = false
      # end

      yi = pos.yi + el.itop
      yl = pos.yl - el.ibottom
      #first
      #ch
      #x
      #y

      if (pos.yi < 0)
        return pos._clean_sides = false
      end
      if (pos.yl > height)
        return pos._clean_sides = false
      end
      if ((pos.xi - 1) < 0)
        return pos._clean_sides = true
      end
      if (pos.xl > width)
        return pos._clean_sides = true
      end

      x = pos.xi-1
      while x >= 0
        if (!@olines[yi]?)
          break
        end
        first = @olines[yi][x]
        (yi...yl).each do |y|
          if (!@olines[y]? || !@olines[y][x]?)
            break
          end
          ch = @olines[y][x]
          if ((ch.attr != first.attr) || (ch.char != first.char))
            return pos._clean_sides = false
          end
        end
        x -= 1
      end

      (pos.xl...width).each do |x|
        if (!@olines[yi]?)
          break
        end
        first = @olines[yi][x]
        (yi...yl).each do |y|
          if (!@olines[y] || !@olines[y][x])
            break
          end
          ch = @olines[y][x]
          if ((ch.attr != first.attr) || (ch.char != first.char))
            return pos._clean_sides = false
          end
        end
        x += 1
      end

      pos._clean_sides = true
    end

    def _get_pos
      self
    end

    def _dock_borders
      lines = @lines
      stops = @_border_stops
      #i
      #y
      #x
      #ch

      # D O:
      # keys, stop
      # keys = Object.keys(this._borderStops)
      #   .map(function(k) { return +k; })
      #   .sort(function(a, b) { return a - b; })
      #
      # for (i = 0; i < keys.length; i++)
      #   y = keys[i]
      #   if (!lines[y]) continue
      #   stop = this._borderStops[y]
      #   for (x = stop.xi; x < stop.xl; x++)

      stops = stops.keys.map(&.to_i).sort { |a, b| a - b }

      stops.each do |y|
        if (!lines[y]?)
          next
        end
        width.times do |x|
          ch = lines[y][x].char
          if @angles[ch]?
            lines[y][x].char = _get_angle lines, x, y
            lines[y].dirty = true
          end
        end
      end
    end

    def _get_angle(lines, x, y)
      angle = 0
      attr = lines[y][x].attr
      ch = lines[y][x].char

      if (lines[y][x - 1]? && @langles[lines[y][x - 1].char]?)
        if (!@ignore_dock_contrast)
          if (lines[y][x - 1].attr != attr)
            return ch
          end
        end
        angle |= 1 << 3
      end

      if (lines[y - 1]? && @uangles[lines[y - 1][x].char]?)
        if (!@ignore_dock_contrast)
          if (lines[y - 1][x].attr != attr)
            return ch
          end
        end
        angle |= 1 << 2
      end

      if (lines[y][x + 1]? && @rangles[lines[y][x + 1].char]?)
        if (!@ignore_dock_contrast)
          if (lines[y][x + 1].attr != attr)
            return ch
          end
        end
        angle |= 1 << 1
      end

      if (lines[y + 1]? && @dangles[lines[y + 1][x].char]?)
        if (!@ignore_dock_contrast)
          if (lines[y + 1][x].attr != attr)
            return ch
          end
        end
        angle |= 1 << 0
      end

      # Experimental: fixes this situation:
      # +----------+
      #            | <-- empty space here, should be a T angle
      # +-------+  |
      # |       |  |
      # +-------+  |
      # |          |
      # +----------+
      # if (uangles[lines[y][x][1]])
      #   if (lines[y + 1] && cdangles[lines[y + 1][x][1]])
      #     if (!@options.ignoreDockContrast)
      #       if (lines[y + 1][x][0] != attr) return ch
      #     }
      #     angle |= 1 << 0
      #   }
      # }

      @angle_table[angle]? || ch
    end

    # Convert an SGR string to our own attribute format.
    def attr_code(code, cur, dfl)
      if cur.is_a? Char
        raise "It's a char ey"
      end
      flags = (cur >> 18) & 0x1ff
      fg = (cur >> 9) & 0x1ff
      bg = cur & 0x1ff
      #c
      #i

      code = code[2...-1].split(';')
      if (!code[0]? || code[0].empty?)
        code[0] = "0"
      end

      (0..code.size).each do |i|
        c = !code[i].empty? ? code[i].to_i : 0
        case c
          when 0 # normal
            bg = dfl & 0x1ff
            fg = (dfl >> 9) & 0x1ff
            flags = (dfl >> 18) & 0x1ff
            break
          when 1 # bold
            flags |= 1
            break
          when 22
            flags = (dfl >> 18) & 0x1ff
            break
          when 4 # underline
            flags |= 2
            break
          when 24
            flags = (dfl >> 18) & 0x1ff
            break
          when 5 # blink
            flags |= 4
            break
          when 25
            flags = (dfl >> 18) & 0x1ff
            break
          when 7 # inverse
            flags |= 8
            break
          when 27
            flags = (dfl >> 18) & 0x1ff
            break
          when 8 # invisible
            flags |= 16
            break
          when 28
            flags = (dfl >> 18) & 0x1ff
            break
          when 39 # default fg
            fg = (dfl >> 9) & 0x1ff
            break
          when 49 # default bg
            bg = dfl & 0x1ff
            break
          when 100 # default fg/bg
            fg = (dfl >> 9) & 0x1ff
            bg = dfl & 0x1ff
            break
          else # color
            if (c == 48 && code[i+1] == 5)
              i += 2
              bg = code[i]
              break
            elsif (c == 48 && code[i+1] == 2)
              i += 2
              bg = Colors.match(code[i].to_i, code[i+1].to_i, code[i+2].to_i)
              if (bg == -1)
                bg = dfl & 0x1ff
              end
              i += 2
              break
            elsif (c == 38 && code[i+1] == 5)
              i += 2
              fg = code[i]
              break
            elsif (c == 38 && code[i+1] == 2)
              i += 2
              fg = Colors.match(code[i].to_i, code[i+1].to_i, code[i+2].to_i)
              if (fg == -1)
                fg = (dfl >> 9) & 0x1ff
              end
              i += 2
              break
            end
            if (c >= 40 && c <= 47)
              bg = c - 40
            elsif (c >= 100 && c <= 107)
              bg = c - 100
              bg += 8
            elsif (c == 49)
              bg = dfl & 0x1ff
            elsif (c >= 30 && c <= 37)
              fg = c - 30
            elsif (c >= 90 && c <= 97)
              fg = c - 90
              fg += 8
            elsif (c == 39)
              fg = (dfl >> 9) & 0x1ff
            elsif (c == 100)
              fg = (dfl >> 9) & 0x1ff
              bg = dfl & 0x1ff
            end
            break
        end
      end

      if flags.is_a? Int32 && fg.is_a? Int32 && bg.is_a? Int32
        (flags << 18) | (fg << 9) | bg
      else
        raise "Vars are string?!"
      end
    end

    # Unused; just compatibility with `Node` interface.
    def clear_pos
    end

  end

end
