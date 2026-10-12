module Crysterm
  module Event
    # Emitted by a `Neovim::Handler` when Neovim's mode changes
    # (`Neovim::Handler#mode`): Normal, Insert, Visual, …
    event ViModeChanged, mode : Neovim::Mode

    # Emitted by a `Neovim::Handler` when the command line Neovim is reading
    # changes (`Neovim::Handler#command_line`): the text with its prompt
    # (`:w`, `/pat`), or `nil` once it is closed.
    event ViCommandLineChanged, text : String?

    # Emitted by a `Neovim::Handler` when the message Neovim shows changes
    # (`Neovim::Handler#message`): its text and kind (Neovim's `msg_show`
    # kinds: `"emsg"` an error, `"echo"`, `"wmsg"`, …), or `nil` and `""`
    # once Neovim cleared it.
    event ViMessageChanged, text : String?, kind : String = ""

    # Emitted by a `Neovim::Handler` when `:w` (`:write`, `:up`, `:wq`, `:x`,
    # `ZZ`) asks to write the buffer: Neovim writes nothing itself, the
    # application saves the widget's text — to its own file when *path* is
    # `nil`, else to *path* (`:w other.txt`, a full path). *bang* is `:w!`'s.
    event ViWriteRequested, path : String?, bang : Bool = false

    # Emitted by a `Neovim::Handler` when `:q` (`:quit`, `:wq`, `:x`, `ZZ`,
    # `ZQ`) asks to quit, after any write it asked for: Neovim quits nothing
    # itself, the application closes the editor or quits as its own commands
    # do. *bang* is `:q!`'s (discard changes), *all* `:qa`'s.
    event ViQuitRequested, bang : Bool = false, all : Bool = false
  end

  module Neovim
    # The mode an embedded Neovim is in, as a `Neovim::Handler` reports it
    # (`nvim_get_mode`).
    enum Mode
      Normal
      Insert
      Replace
      Visual
      VisualLine
      VisualBlock
      Select
      CommandLine
      OperatorPending
      # A mode none of the above stands for: a prompt, the terminal.
      Other

      # The mode `nvim_get_mode` names *mode* (`"n"`, `"no"`, `"i"`, `"V"`,
      # `"\x16"`, `"c"`, `"Rv"`, …).
      def self.from_nvim(mode : String) : Mode
        return OperatorPending if mode.starts_with?("no")
        case mode[0]?
        when 'n'                then Normal
        when 'i'                then Insert
        when 'R'                then Replace
        when 'v'                then Visual
        when 'V'                then VisualLine
        when '\u0016'           then VisualBlock
        when 's', 'S', '\u0013' then Select
        when 'c'                then CommandLine
        else                         Other
        end
      end

      # Whether text is selected in this mode (the Visual and Select modes).
      def selecting? : Bool
        visual? || visual_line? || visual_block? || select?
      end

      # The name Neovim's `showmode` gives the mode, in capitals, for a
      # status bar: `NORMAL`, `INSERT`, `VISUAL`, `V-LINE`, `V-BLOCK`, …
      def label : String
        case self
        in .normal?           then "NORMAL"
        in .insert?           then "INSERT"
        in .replace?          then "REPLACE"
        in .visual?           then "VISUAL"
        in .visual_line?      then "V-LINE"
        in .visual_block?     then "V-BLOCK"
        in .select?           then "SELECT"
        in .command_line?     then "COMMAND"
        in .operator_pending? then "O-PENDING"
        in .other?            then "OTHER"
        end
      end
    end

    # Vi editing for a text input widget, by an embedded Neovim: the
    # `FakeVimHandler` of Qt Creator, installed on an editor much as an event
    # filter is, with headless Neovim as the engine — as vscode-neovim does
    # it — while the widget keeps its own document and drawing.
    #
    # ```
    # handler = Crysterm::Neovim::Handler.new
    # handler.attach editor # => false when Neovim cannot run
    # handler.on(Crysterm::Event::ViModeChanged) { |e| status.text = e.mode.label }
    # handler.on(Crysterm::Event::ViWriteRequested) { save }
    # handler.on(Crysterm::Event::ViQuitRequested) { |e| quit force: e.bang }
    # ```
    #
    # It works on any widget that includes `Mixin::TextEditing`
    # (`Widget::TextEdit`, `Widget::PlainTextEdit`, `Widget::LineEdit`)
    # through that mixin's buffer protocol, one Neovim buffer per widget:
    #
    # * **Keys.** A key press on the widget goes to Neovim (`nvim_input`) and
    #   no further, except the keys `#pass_through` lets on — by default the
    #   function keys and the `Alt` combinations, which an application's menus
    #   and shortcuts use. A single-line widget (`Mixin::TextEditing#single_line?`)
    #   also keeps `Enter` (outside Neovim's command line) and, in Normal
    #   mode, `Escape`, so a prompt is still submitted and cancelled. Each key
    #   is waited on until Neovim has taken it and the widget mirrors the
    #   result (at most `#sync_timeout`), so the widget is current when the
    #   key handler returns. A bracketed paste goes to Neovim too
    #   (`nvim_paste`, one undo step there).
    # * **Neovim to widget.** Every change Neovim makes to its buffer reaches
    #   the widget as the changed lines, applied as the smallest edit that
    #   turns the widget's text into Neovim's (`Mixin::TextEditing#apply_external_edit`):
    #   the text outside the change keeps its formats, and the widget's undo
    #   stack records each change as one step. Then the caret follows Neovim's
    #   cursor, and Visual mode shows as the widget's selection — whole lines
    #   in Visual Line mode; Visual Block selects from corner to corner, as the
    #   widget has no rectangular selection.
    # * **Widget to Neovim.** A change made to the widget from outside Neovim
    #   — `value=`, an application's menu, a mouse paste, the widget's own
    #   undo — is sent to Neovim as the lines it changed (`nvim_buf_set_lines`,
    #   which Neovim's undo records), and a click or a drag moves Neovim's
    #   cursor or selects in Visual mode. What the handler applies itself is
    #   never sent back.
    # * **Undo.** `u` and `Ctrl-R` are Neovim's, with its undo steps (an
    #   insert is one); the widget's mirror of each change is an undo step of
    #   the widget too, so an application's own Undo still works on the
    #   widget, and what it undoes reaches Neovim as an outside change.
    # * **A single line.** A single-line widget's buffer is kept to one line:
    #   what would make another (`o`, a pasted line break, a linewise put) is
    #   joined back on with a space, as `Widget::LineEdit` flattens a paste.
    # * **Mode, command line, messages.** A minimal UI is attached
    #   (`ext_cmdline`, `ext_messages`): `#mode`, `#command_line`,
    #   `#message` and `#pending_keys` say what Neovim shows, and
    #   `Event::ViModeChanged`, `ViCommandLineChanged` and `ViMessageChanged`
    #   tell an application's status bar. The widget's caret is a block in
    #   Normal and Visual mode, a bar while inserting and on the command line,
    #   an underline in Replace and Operator-pending mode.
    # * **`:w`, `:q`.** The buffer is written by the application, not by
    #   Neovim: `:w`, `:up` and the writes of `:wq`, `:x` and `ZZ` emit
    #   `Event::ViWriteRequested`, `:q`, `:qa`, `:wq`, `:x`, `ZZ` and `ZQ`
    #   emit `Event::ViQuitRequested` (FakeVim's `writeAllRequested`,
    #   `quitRequested`), and Neovim keeps running.
    # * **Neovim gone.** When Neovim cannot be started `#attach` returns
    #   false and leaves the widget alone; when it exits, the handler detaches
    #   and emits `Event::ProcessExited`. Either way the widget edits as it
    #   does without one.
    #
    # Neovim runs as `nvim --embed` with `#args` (`--headless --clean -n` by
    # default; leave out `--clean` for the user's own config). The handler
    # starts one at `#attach` and ends it at `#detach`, unless a `Client` is
    # given to share: several handlers on one Neovim each have a buffer of
    # their own, the focused widget's shown in Neovim's window.
    class Handler
      include EventHandler

      # The arguments `nvim --embed` is started with when no `Client` is given.
      class_property default_args : Array(String) = ["--headless", "--clean", "-n"]

      # Whether *e* goes on to the widget and the window rather than to
      # Neovim: the function keys (`<F1>`…) and every `Alt` combination
      # (`<M-x>`, `<M-Up>`, `<C-M-a>`), with which an application's menus
      # and shortcuts are reached.
      def self.default_pass_through?(e : ::Crysterm::Event::KeyPress) : Bool
        n = Keys.notation(e) || return false
        n.matches?(/\A<(?:[SC]-)*M-/) || n.matches?(/\A<(?:[SCMD]-)*F\d+>\z/)
      end

      # The arguments the handler's own Neovim is started with (see the class
      # docs); read at `#attach`.
      property args : Array(String)

      # The Neovim executable the handler's own Neovim runs (`Neovim.executable`).
      property executable : String

      # Which key presses go on to the widget and the window instead of to
      # Neovim (`.default_pass_through?` by default).
      property pass_through : Proc(::Crysterm::Event::KeyPress, Bool) = ->Handler.default_pass_through?(::Crysterm::Event::KeyPress)

      # How long a key press waits for Neovim to have taken it and for the
      # widget to mirror the result.
      property sync_timeout : Time::Span = 1.second

      # Whether the caret's shape follows the mode (see the class docs).
      property? cursor_shapes : Bool = true

      # The widget the handler is attached to, or `nil`.
      getter widget : Widget?

      # The widget seen through `Mixin::TextEditing`, with its concrete type
      # (a value typed by the module alone would be its classes' common
      # ancestor to the compiler, which has none of the mixin's methods).
      @target : Target?

      # The Neovim spoken to while attached: the one given to share, or the
      # handler's own.
      getter client : Client?

      # The widget's buffer in Neovim, while attached.
      getter buffer : Int64?

      # Neovim's mode (`Event::ViModeChanged` when it changes).
      getter mode : Mode = Mode::Normal

      # The command line Neovim is reading, with its prompt (`:w`, `/pat`),
      # or `nil` (`Event::ViCommandLineChanged`).
      getter command_line : String? = nil

      # The message Neovim shows, or `nil` (`Event::ViMessageChanged`).
      getter message : String? = nil

      # The kind of `#message` (`"emsg"` for an error, …).
      getter message_kind : String = ""

      # The keys of a command not yet complete (`showcmd`: `d`, `2y`, `"a`).
      getter pending_keys : String = ""

      # The buffer's lines as Neovim has them; the widget's text is their
      # join with `\n` (with a space for a single-line widget), followed by a
      # `\n` when `@eol` is set. A final newline ends the last line, as in a
      # file Neovim reads ('endofline'), rather than starting an empty one,
      # so `G` and `o` there act as on the file.
      @lines = [""]
      @eol = false
      @owns_client = false
      @subs = ::Crysterm::Subscriptions.new
      @notification : Client::NotificationHandler?

      # The `Client#on_exit` block `#setup` added, removed by `#teardown`.
      @exit_handler : Client::ExitHandler?

      # Set while the handler itself changes the widget, whose events are
      # then no outside change.
      @applying = false
      @text_dirty = false
      @caret_dirty = false
      @flush_scheduled = false
      @seq = 0_i64
      @waiter : {Int64, Channel(Nil)}? = nil
      @mode_dirty = false
      # The widget's own caret shape, given back at `#detach`.
      @saved_shape : ::Tput::CursorShape? = nil
      @saved_blink = false
      @read_only = false

      # Neovim the handler is on, by client, for the buffer shown in its
      # window (several handlers sharing one client).
      @@shown = {} of UInt64 => Int64

      # One lock per client, held by a handler while it sends Neovim a change
      # and then keys. `nvim_input` is a fast call: its keys reach Neovim's
      # typeahead at once, ahead of a call sent before them still waiting in
      # Neovim's event queue (a buffer switch, the widget's lines). So such a
      # call is a request, its answer awaited before any key is sent, and the
      # lock keeps a handler sharing the client from sending keys meanwhile.
      @@locks = {} of UInt64 => Mutex

      # *client* is a Neovim to share (never ended by the handler); without
      # one the handler starts its own at `#attach` with *args*.
      def initialize(@client : Client? = nil, @args : Array(String) = Handler.default_args.dup,
                     @executable : String = Neovim.executable)
      end

      # Whether the handler is attached to a widget.
      def attached? : Bool
        !@widget.nil?
      end

      # Attaches to *widget*, detaching from any other first: starts Neovim
      # unless one is shared, gives the widget a buffer holding its text and
      # takes its keys. Returns false — the widget left as it was — when
      # Neovim cannot be started or set up.
      def attach(widget : Mixin::TextEditing) : Bool
        attach_target TargetOf.new(widget)
      end

      private def attach_target(target : Target) : Bool
        detach
        client = @client
        owns = client.nil?
        begin
          client ||= Client.new(args: @args, executable: @executable)
        rescue ex : Error
          ::Log.warn { "Crysterm::Neovim::Handler: #{ex.message}" }
          return false
        end
        @client = client
        @owns_client = owns
        begin
          setup client, target
        rescue ex : Error
          ::Log.warn { "Crysterm::Neovim::Handler: #{ex.message}" }
          teardown
          return false
        end
        true
      end

      # Gives the widget back its own key handling: drops the handler's
      # subscriptions, restores the caret's shape, and deletes the buffer
      # from a shared Neovim or ends the handler's own.
      def detach : Nil
        w = @widget
        teardown
        restore_cursor w if w
      end

      # Sends *keys*, in Neovim's key notation (`"dd"`, `"<Esc>"`, `":w<CR>"`),
      # as if typed into the widget, and waits until the widget mirrors what
      # they did (at most `#sync_timeout`).
      def input(keys : String) : Nil
        client = @client || return
        exclusive(client) do
          flush_pending
          show_buffer client
          sync_read_only client
          client.notify "nvim_input", keys
        end
        sync
      rescue Error
        gone
      end

      # Waits until the widget mirrors everything Neovim did so far (at most
      # `#sync_timeout`).
      def sync : Nil
        request_state wait: true
      end

      private def setup(client : Client, target : Target) : Nil
        widget = target.widget
        chan = client.channel_id
        client.request "nvim_exec_lua", LUA, [chan]
        buf = client.request("nvim_create_buf", true, false).as_i64
        @buffer = buf
        @widget = widget
        @target = target
        @lines, @eol = split_lines target
        @mode = Mode::Normal
        @command_line = nil
        @message = nil
        @pending_keys = ""
        @read_only = target.read_only?
        client.request "nvim_exec_lua", "crysterm_vi.attach(...)", [buf, target.single_line?, @lines, !@read_only]
        @notification = client.on_notification { |method, params| notified client, method, params }
        @exit_handler = client.on_exit { |code| exited client, code }
        client.request "nvim_win_set_buf", 0_i64, buf
        @@shown[client.object_id] = buf
        begin
          client.request "nvim_ui_attach", *ui_size(widget), {"ext_linegrid" => true, "ext_cmdline" => true, "ext_messages" => true, "rgb" => true}
        rescue Error
          # A shared Neovim has a UI attached already.
        end
        push_caret client, target, Mode::Normal

        @subs.on(widget, ::Crysterm::Event::KeyPress, at: ::EventHandler.at_beginning) { |e| key_pressed e }
        @subs.on(widget, ::Crysterm::Event::Paste, at: ::EventHandler.at_beginning) { |e| pasted e }
        @subs.on(widget, ::Crysterm::Event::TextChanged) { outside_change text: true }
        target.on_document_change(@subs) { outside_change text: true }
        @subs.on(widget, ::Crysterm::Event::CursorPositionChanged) { outside_change caret: true }
        @subs.on(widget, ::Crysterm::Event::SelectionChanged) { outside_change caret: true }
        @subs.on(widget, ::Crysterm::Event::FocusIn) { focused }
        @subs.on(widget, ::Crysterm::Event::Resize) { resized }
        @subs.auto_dispose(widget) { detach }

        @saved_shape = widget.cursor.try &.shape
        @saved_blink = widget.cursor.try(&.blink) || false
        apply_cursor_shape
        request_state wait: true
      end

      # Undoes `#setup`, as far as it got.
      private def teardown : Nil
        @subs.off
        client = @client
        if client && (h = @notification)
          client.off_notification h
        end
        @notification = nil
        if client && (eh = @exit_handler)
          client.off_exit eh
        end
        @exit_handler = nil
        if client
          @@shown.delete(client.object_id) if @@shown[client.object_id]? == @buffer
          if @owns_client
            @@locks.delete client.object_id
            # Let go of the client first: its exit, reported while `#close`
            # waits for it, is then no Neovim ending under the widget
            # (`#exited`), and emits no `Event::ProcessExited`.
            @client = nil
            client.close
          elsif client.running? && (buf = @buffer)
            client.notify("nvim_buf_delete", buf, {"force" => true}) rescue nil
          end
        end
        @buffer = nil
        @widget = nil
        @target = nil
        if w = @waiter
          @waiter = nil
          w[1].send nil
        end
      end

      private def restore_cursor(widget : Widget) : Nil
        return unless @cursor_shapes
        if shape = @saved_shape
          widget.set_cursor shape, blink: @saved_blink
        else
          widget.reset_cursor
        end
        @saved_shape = nil
      end

      # The client's Neovim exited: the widget is on its own again.
      private def exited(client : Client, code : Int32?) : Nil
        return unless client.same?(@client) && attached?
        gone
        emit ::Crysterm::Event::ProcessExited, code
      end

      # Neovim cannot be reached any more.
      private def gone : Nil
        detach
      end

      private def ui_size(widget : Widget) : {Int32, Int32}
        {Math.max(widget.awidth, 10), Math.max(widget.aheight, 1)}
      rescue
        {80, 24}
      end

      # The widget's text as Neovim's lines, and whether it ends with a
      # newline that ends its last line.
      private def split_lines(target : Target) : {Array(String), Bool}
        text = target.value
        return {[text.tr("\n", " ")], false} if target.single_line?
        eol = text.ends_with?('\n')
        text = text.rchop if eol
        lines = text.split('\n')
        {lines.empty? ? [""] : lines, eol}
      end

      # The widget's text as Neovim's lines make it.
      private def joined_lines(sep : String) : String
        text = @lines.join(sep)
        @eol ? text + "\n" : text
      end

      private def separator : String
        @target.try(&.single_line?) ? " " : "\n"
      end

      # Keys ---------------------------------------------------------------

      private def key_pressed(e : ::Crysterm::Event::KeyPress) : Nil
        return if e.accepted?
        return unless target = @target
        return if @pass_through.call(e)
        keys = Keys.notation(e) || return
        if target.single_line?
          return if (keys == "<CR>" || keys == "<kEnter>") && !@mode.command_line?
          return if keys == "<Esc>" && @mode.normal? && @pending_keys.empty?
        end
        # Taken: accepted, so it goes no further up, and blanked, so the
        # widget's own handlers after this one see no key (as
        # `Mixin::PopupController#consume` does).
        e.accept
        e.key = nil
        e.char = '\u0000'
        input keys
      end

      private def pasted(e : ::Crysterm::Event::Paste) : Nil
        return if e.accepted?
        client = @client || return
        return if @target.try &.read_only?
        e.accept
        exclusive(client) do
          flush_pending
          show_buffer client
          client.request "nvim_paste", e.content, true, -1
        end
        sync
      rescue Error
        gone
      end

      # Makes the widget's buffer the one in Neovim's window, for a shared
      # Neovim whose window showed another handler's.
      private def show_buffer(client : Client) : Nil
        buf = @buffer || return
        return if @@shown[client.object_id]? == buf
        @@shown[client.object_id] = buf
        client.request "nvim_win_set_buf", 0_i64, buf
        if t = @target
          push_caret client, t, @mode
          resized
        end
      end

      private def sync_read_only(client : Client) : Nil
        t = @target || return
        buf = @buffer || return
        ro = t.read_only?
        return if ro == @read_only
        @read_only = ro
        client.request "nvim_exec_lua", "vim.bo[...].modifiable = select(2, ...)", [buf, !ro]
      end

      private def focused : Nil
        apply_cursor_shape
        if c = @client
          exclusive(c) { show_buffer c }
        end
      rescue Error
        gone
      end

      private def resized : Nil
        return unless (c = @client) && (w = @widget) && @@shown[c.object_id]? == @buffer
        cols, rows = ui_size w
        c.notify "nvim_ui_try_resize", cols, rows
      rescue Error
      end

      # State --------------------------------------------------------------

      # Asks Neovim for its mode and cursor, answered by a notification
      # after every change it made before (`#state_received`); with *wait*,
      # parks the calling fiber until then.
      private def request_state(wait : Bool) : Nil
        flush_external if wait
        client = @client || return
        buf = @buffer || return
        seq = (@seq += 1)
        ch = nil
        if wait
          ch = Channel(Nil).new 1
          @waiter = {seq, ch}
        end
        client.notify "nvim_exec_lua", "crysterm_vi.state(...)", [buf, seq]
        if ch
          select
          when ch.receive
          when timeout(@sync_timeout)
          end
          if (w = @waiter) && w[0] == seq
            @waiter = nil
          end
        end
      rescue Error
        gone
      end

      # Neovim's notifications, on the client's dispatch fiber, in order.
      private def notified(client : Client, method : String, params : Array(MessagePack::Type)) : Nil
        return unless client.same?(@client)
        buf = @buffer || return
        case method
        when "crysterm_vi_lines"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          lines_changed params[1].as(Int).to_i32, params[2].as(Int).to_i32,
            params[3].as(Array).map(&.to_s)
        when "crysterm_vi_state"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          state_received params
        when "crysterm_vi_write"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          emit ::Crysterm::Event::ViWriteRequested, params[1]?.as?(String), params[2]? == true
        when "crysterm_vi_quit"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          emit ::Crysterm::Event::ViQuitRequested, params[1]? == true, params[2]? == true
        when "redraw"
          redraw params if @@shown[client.object_id]? == buf
        when "nvim_error_event"
          show_message params[1]?.to_s, "emsg"
        end
      end

      private def state_received(params : Array(MessagePack::Type)) : Nil
        seq = params[1].as(Int).to_i64
        mode = Mode.from_nvim params[2].to_s
        row = params[3].as(Int).to_i32 - 1
        col = params[4].as(Int).to_i32
        vrow = params[5].as(Int).to_i32 - 1
        vcol = params[6].as(Int).to_i32
        set_mode mode
        # An outside change not yet sent wins over where Neovim was; a
        # buffer not in Neovim's window has no cursor to follow.
        if (target = @target) && !@text_dirty && !@caret_dirty && params[7]? == true
          caret_from_nvim target, mode, row, col, vrow, vcol
        end
        if (w = @waiter) && seq >= w[0]
          @waiter = nil
          w[1].send nil
        end
      end

      private def set_mode(mode : Mode) : Nil
        return if mode == @mode
        @mode = mode
        apply_cursor_shape
        emit ::Crysterm::Event::ViModeChanged, mode
      end

      private def apply_cursor_shape : Nil
        return unless @cursor_shapes
        widget = @widget || return
        shape =
          case @mode
          when .insert?, .command_line?      then ::Tput::CursorShape::Line
          when .replace?, .operator_pending? then ::Tput::CursorShape::Underline
          else                                    ::Tput::CursorShape::Block
          end
        widget.set_cursor shape unless widget.cursor_shape == shape
      end

      # Puts the widget's caret and selection where Neovim's cursor and
      # Visual selection are: *row* and *col* the cursor (0-based row, byte
      # column), *vrow* and *vcol* the other end of the selection.
      private def caret_from_nvim(target : Target, mode : Mode, row : Int32, col : Int32, vrow : Int32, vcol : Int32) : Nil
        cur = flat_position row, col
        anchor = nil
        if mode.visual_line?
          if row >= vrow
            anchor = line_offset(vrow)
            cur = line_offset(row) + line_at(row).size
          else
            anchor = line_offset(vrow) + line_at(vrow).size
            cur = line_offset(row)
          end
        elsif mode.selecting?
          v = flat_position vrow, vcol
          if cur >= v
            anchor = v
            cur = Math.min(cur + 1, target.buf_size)
          else
            anchor = Math.min(v + 1, target.buf_size)
          end
        end
        applying { target.set_caret cur, anchor }
      end

      private def line_at(row : Int32) : String
        @lines[row.clamp(0, @lines.size - 1)]
      end

      # The widget position of line *row*'s start.
      private def line_offset(row : Int32) : Int32
        row = row.clamp(0, @lines.size)
        off = 0
        row.times { |i| off += @lines[i].size + 1 }
        off
      end

      # The widget position of byte column *col* on line *row*.
      private def flat_position(row : Int32, col : Int32) : Int32
        line = line_at(row)
        line_offset(row.clamp(0, @lines.size - 1)) + char_column(line, col)
      end

      private def char_column(line : String, col : Int32) : Int32
        return line.size if col >= line.bytesize
        return 0 if col <= 0
        line.byte_index_to_char_index(col) || String.new(line.to_slice[0, col]).size
      end

      # The `{row, byte column}` of widget position *pos*.
      private def nvim_position(pos : Int32) : {Int32, Int32}
        off = 0
        @lines.each_with_index do |line, row|
          if pos <= off + line.size || row == @lines.size - 1
            c = (pos - off).clamp(0, line.size)
            return {row, line.char_index_to_byte_index(c) || line.bytesize}
          end
          off += line.size + 1
        end
        {0, 0}
      end

      private def applying(&)
        was = @applying
        @applying = true
        begin
          yield
        ensure
          @applying = was
        end
      end

      # The UI's events: the mode, the command line, the messages.
      private def redraw(params : Array(MessagePack::Type)) : Nil
        params.each do |batch|
          a = batch.as?(Array(MessagePack::Type)) || next
          name = a[0]?.to_s
          a.each_with_index do |args, i|
            next if i == 0
            args = args.as?(Array(MessagePack::Type)) || next
            case name
            when "mode_change"
              @mode_dirty = true
            when "cmdline_show"
              content = chunks_text args[0]?
              firstc = args[2]?.to_s
              prompt = args[3]?.to_s
              indent = args[4]?.as?(Int).try(&.to_i) || 0
              set_command_line "#{prompt}#{firstc}#{" " * indent}#{content}"
            when "cmdline_hide"
              set_command_line nil
            when "msg_show"
              kind = args[0]?.to_s
              text = chunks_text args[1]?
              show_message text, kind unless text.empty? && kind.empty?
            when "msg_clear"
              show_message nil, ""
            when "msg_showcmd"
              @pending_keys = chunks_text args[0]?
            end
          end
          if name == "flush" && @mode_dirty
            @mode_dirty = false
            request_state wait: false
          end
        end
      end

      private def chunks_text(chunks) : String
        return "" unless list = chunks.as?(Array(MessagePack::Type))
        String.build do |io|
          list.each do |chunk|
            if c = chunk.as?(Array(MessagePack::Type))
              io << c[1]?.to_s
            end
          end
        end
      end

      private def set_command_line(text : String?) : Nil
        return if text == @command_line
        @command_line = text
        emit ::Crysterm::Event::ViCommandLineChanged, text
      end

      private def show_message(text : String?, kind : String) : Nil
        text = nil if text.try &.empty?
        return if text == @message && kind == @message_kind
        @message = text
        @message_kind = kind
        emit ::Crysterm::Event::ViMessageChanged, text, kind
      end

      # Neovim to widget -----------------------------------------------------

      # Neovim replaced lines *first*...*last* of its buffer with *data*:
      # the same lines of the widget's text get the smallest edit that makes
      # them so.
      private def lines_changed(first : Int32, last : Int32, data : Array(String)) : Nil
        target = @target || return
        sep = separator
        n = @lines.size
        first = first.clamp(0, n)
        last = last.clamp(first, n)
        total = line_offset(n) - 1
        a = line_offset(first)
        old = @lines[first...last]
        old_text = old.join(sep)
        new_text = data.join(sep)
        s, e, ins =
          if !old.empty? && !data.empty?
            {a, a + old_text.size, new_text}
          elsif old.empty? && !data.empty?
            first < n ? {a, a, new_text + sep} : {total, total, sep + new_text}
          elsif !old.empty?
            if last < n
              {a, a + old_text.size + 1, ""}
            elsif first > 0
              {a - 1, total, ""}
            else
              {0, total, ""}
            end
          else
            return
          end
        @lines[first...last] = data
        @lines << "" if @lines.empty?
        if target.buf_size != total + (@eol ? 1 : 0)
          # Out of step (an edit the handler did not see): take Neovim's
          # whole text.
          s, e, ins = 0, target.buf_size, joined_lines(sep)
        end
        replace target, s, e, ins
      end

      # Turns the widget's `[from, to)` into *text* by the smallest edit:
      # the common start and end are left alone.
      private def replace(target : Target, from : Int32, to : Int32, text : String) : Nil
        old = target.buf_slice(from, to).chars
        new = text.chars
        p, q = common_ends(old, new)
        del_from = from + p
        del_to = to - q
        ins = new[p...(new.size - q)].join
        return if del_from == del_to && ins.empty?
        applying { target.edit del_from, del_to, ins }
      end

      # How many elements *old* and *new* share at their start, and then at
      # their end (not overlapping the start).
      private def common_ends(old : Array, new : Array) : {Int32, Int32}
        p = 0
        while p < old.size && p < new.size && old[p] == new[p]
          p += 1
        end
        q = 0
        while q < old.size - p && q < new.size - p && old[old.size - 1 - q] == new[new.size - 1 - q]
          q += 1
        end
        {p, q}
      end

      # Widget to Neovim -----------------------------------------------------

      # The widget changed by other means than the handler's: sent to Neovim
      # once the current fiber yields, or before the next key.
      private def outside_change(text : Bool = false, caret : Bool = false) : Nil
        return if @applying
        @text_dirty ||= text
        @caret_dirty ||= caret
        return if @flush_scheduled
        @flush_scheduled = true
        spawn(name: "Neovim::Handler flush") { flush_external }
      end

      private def flush_external : Nil
        @flush_scheduled = false
        client = @client || return
        exclusive(client) { flush_pending }
      rescue Error
        gone
      end

      # Holds *client*'s lock (`@@locks`) for the block.
      private def exclusive(client : Client, &)
        (@@locks[client.object_id] ||= Mutex.new).synchronize { yield }
      end

      # Sends what changed outside Neovim; under the client's lock.
      private def flush_pending : Nil
        client = @client || return
        target = @target || return
        return unless @text_dirty || @caret_dirty
        # The text goes to the widget's own buffer, shown or not; the caret
        # only to the window showing it, which a handler sharing the Neovim
        # may have taken: it is sent when the buffer is shown again
        # (`#show_buffer`), as switching here would move the other
        # handler's keys, still in Neovim's queue, to this buffer.
        if @text_dirty
          @text_dirty = false
          push_text client, target
        end
        if @caret_dirty
          @caret_dirty = false
          if @@shown[client.object_id]? == @buffer
            push_caret client, target, @mode
            request_state wait: false
          end
        end
      end

      # Sends Neovim the lines that differ between its buffer and the widget.
      private def push_text(client : Client, target : Target) : Nil
        buf = @buffer || return
        new, @eol = split_lines target
        old = @lines
        return if new == old
        p, q = common_ends(old, new)
        @lines = new
        client.request "nvim_exec_lua", "crysterm_vi.set_lines(...)", [buf, p, old.size - q, new[p...(new.size - q)]]
      end

      # Puts Neovim's cursor on the widget's caret, and its Visual selection
      # on the widget's selection; through the input queue, after the keys
      # before it.
      private def push_caret(client : Client, target : Target, mode : Mode) : Nil
        keys = String.build do |io|
          if range = target.selection_range
            io << "<C-Bslash><C-n>"
            last = Math.max(range.end - 1, range.begin)
            from, to = target.cursor_position <= range.begin ? {last, range.begin} : {range.begin, last}
            io << set_cursor_keys(*nvim_position(from)) << 'v' << set_cursor_keys(*nvim_position(to))
          else
            io << "<C-Bslash><C-n>" if mode.selecting? || mode.operator_pending? || mode.command_line?
            io << set_cursor_keys(*nvim_position(target.cursor_position))
          end
        end
        client.notify "nvim_input", keys
      end

      private def set_cursor_keys(row : Int32, col : Int32) : String
        "<Cmd>call nvim_win_set_cursor(0,[#{row + 1},#{col}])<CR>"
      end

      # The widget as the handler uses it: the `Mixin::TextEditing` calls,
      # made on the widget's own type (see `@target`).
      private abstract class Target
        abstract def widget : Widget
        abstract def value : String
        abstract def single_line? : Bool
        abstract def read_only? : Bool
        abstract def buf_size : Int32
        abstract def buf_slice(from : Int32, to : Int32) : String
        abstract def cursor_position : Int32
        abstract def selection_range : Range(Int32, Int32)?
        abstract def set_caret(pos : Int32, anchor : Int32?) : Nil
        # Replaces `[from, to)` with *text*, one undo step told of as an edit.
        abstract def edit(from : Int32, to : Int32, text : String) : Nil
        # Subscribes *block* to the changes of the widget's document, for a
        # widget with one (`Mixin::TextEditing::DocumentBuffer`), whose edits
        # by a `TextCursor` tell no `Event::TextChanged`.
        abstract def on_document_change(subs : ::Crysterm::Subscriptions, &block : ->) : Nil
      end

      private class TargetOf(W) < Target
        def initialize(@w : W)
        end

        def widget : Widget
          @w
        end

        def value : String
          @w.value
        end

        def single_line? : Bool
          @w.single_line?
        end

        def read_only? : Bool
          @w.read_only?
        end

        def buf_size : Int32
          @w.buf_size
        end

        def buf_slice(from : Int32, to : Int32) : String
          @w.buf_slice from, to
        end

        def cursor_position : Int32
          @w.cursor_position
        end

        def selection_range : Range(Int32, Int32)?
          @w.selection_range
        end

        def set_caret(pos : Int32, anchor : Int32?) : Nil
          @w.set_caret pos, anchor
        end

        def edit(from : Int32, to : Int32, text : String) : Nil
          @w.apply_external_edit do
            @w.buf_delete(from, to) if to > from
            @w.buf_insert(from, text) unless text.empty?
          end
        end

        def on_document_change(subs : ::Crysterm::Subscriptions, &block : ->) : Nil
          w = @w
          if w.is_a?(Mixin::TextEditing::DocumentBuffer)
            subs.on(w.document, ::Crysterm::Event::ContentsChanged) { block.call }
          end
        end
      end

      # The Lua side, run once per attach (idempotent): `crysterm_vi.attach`
      # sets a buffer up, `state` answers with the mode and cursor, and
      # `set_lines` takes the widget's changes without sending them back.
      LUA = <<-LUA
        local chan = ...
        local C = _G.crysterm_vi or { quiet = {} }
        _G.crysterm_vi = C
        C.chan = chan
        vim.o.hidden = true
        vim.o.more = false
        vim.o.swapfile = false

        local function quit(bang, all, write)
          local buf = vim.api.nvim_get_current_buf()
          if write == 'write' then
            vim.cmd(bang and 'write!' or 'write')
          elseif write == 'update' then
            vim.cmd('update')
          end
          vim.rpcnotify(C.chan, 'crysterm_vi_quit', buf, bang, all)
        end
        for name, spec in pairs({
          CrystermQuit = { false }, CrystermQuitAll = { true },
          CrystermWriteQuit = { false, 'write' }, CrystermWriteQuitAll = { true, 'write' },
          CrystermExit = { false, 'update' }, CrystermExitAll = { true, 'update' },
        }) do
          vim.api.nvim_create_user_command(name, function(o) quit(o.bang, spec[1], spec[2]) end, { bang = true, bar = true })
        end
        for short, cmd in pairs({
          q = 'CrystermQuit', quit = 'CrystermQuit',
          qa = 'CrystermQuitAll', qall = 'CrystermQuitAll', quita = 'CrystermQuitAll', quitall = 'CrystermQuitAll',
          wq = 'CrystermWriteQuit', wqa = 'CrystermWriteQuitAll', wqall = 'CrystermWriteQuitAll',
          x = 'CrystermExit', xi = 'CrystermExit', xit = 'CrystermExit', exi = 'CrystermExit', exit = 'CrystermExit',
          xa = 'CrystermExitAll', xall = 'CrystermExitAll',
        }) do
          vim.cmd(string.format("cnoreabbrev <expr> %s (getcmdtype() ==# ':' && getcmdline() ==# '%s') ? '%s' : '%s'", short, short, cmd, short))
        end
        vim.keymap.set('n', 'ZZ', '<Cmd>CrystermExit<CR>')
        vim.keymap.set('n', 'ZQ', '<Cmd>CrystermQuit!<CR>')

        function C.set_lines(buf, first, last, lines)
          C.quiet[buf] = true
          local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, first, last, false, lines)
          C.quiet[buf] = nil
          if not ok then error(err) end
        end

        function C.join(buf)
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          if #lines < 2 then return end
          local win = vim.fn.bufwinid(buf)
          local row, col = 1, 0
          if win ~= -1 then
            local c = vim.api.nvim_win_get_cursor(win)
            row, col = c[1], c[2]
          end
          local off = 0
          for i = 1, row - 1 do off = off + #lines[i] + 1 end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { table.concat(lines, ' ') })
          if win ~= -1 then pcall(vim.api.nvim_win_set_cursor, win, { 1, off + col }) end
        end

        function C.attach(buf, single, lines, modifiable)
          local bo = vim.bo[buf]
          bo.swapfile = false
          bo.buftype = 'acwrite'
          bo.bufhidden = 'hide'
          vim.api.nvim_buf_set_name(buf, 'crysterm://' .. buf)
          local undolevels = bo.undolevels
          bo.undolevels = -1
          C.set_lines(buf, 0, -1, lines)
          bo.undolevels = undolevels
          bo.modified = false
          bo.modifiable = modifiable
          vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, b, _, first, last, new_last)
              if C.quiet[b] then return end
              vim.rpcnotify(C.chan, 'crysterm_vi_lines', b, first, last, vim.api.nvim_buf_get_lines(b, first, new_last, true))
            end,
          })
          vim.api.nvim_create_autocmd('BufWriteCmd', {
            buffer = buf,
            callback = function(a)
              local path = a.match
              if path == vim.api.nvim_buf_get_name(buf) then path = vim.NIL end
              vim.bo[buf].modified = false
              vim.rpcnotify(C.chan, 'crysterm_vi_write', buf, path, vim.v.cmdbang == 1)
            end,
          })
          if single then
            vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
              buffer = buf,
              callback = function() C.join(buf) end,
            })
          end
        end

        function C.state(buf, seq)
          local m = vim.api.nvim_get_mode().mode
          local c = vim.api.nvim_win_get_cursor(0)
          local v = vim.fn.getpos('v')
          local shown = vim.api.nvim_get_current_buf() == buf
          if not shown then
            c = { 1, 0 }
            v = { 0, 1, 1, 0 }
          end
          vim.rpcnotify(C.chan, 'crysterm_vi_state', buf, seq, m, c[1], c[2], v[2], v[3] - 1, shown)
        end
        LUA
    end
  end
end
