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
    # `ZZ`, `:saveas`) asks to write the buffer: Neovim writes nothing itself,
    # the application saves the widget's text — to its own file when *path*
    # is `nil`, else to *path* (a full path). *rename* tells Vim's two writes
    # to another file apart: set, the buffer was given *path* as its name
    # (`:saveas FILE`, or `:file FILE` and then `:w`), which becomes the
    # widget's file, as File → Save As does; unset (`:w FILE`), a copy is
    # written there and the buffer keeps its name. *bang* is `:w!`'s.
    event ViWriteRequested, path : String?, bang : Bool = false, rename : Bool = false

    # Emitted by a `Neovim::Handler` when `:q` (`:quit`, `:wq`, `:x`, `ZZ`,
    # `ZQ`) asks to quit, after any write it asked for: Neovim quits nothing
    # itself, the application closes the editor or quits as its own commands
    # do. *bang* is `:q!`'s (discard changes), *all* `:qa`'s.
    event ViQuitRequested, bang : Bool = false, all : Bool = false

    # Emitted by a `Neovim::Handler` that detached itself from its widget
    # while Neovim kept running: the widget's buffer was closed in Neovim
    # (`:bwipeout`, `:bdelete`, `:edit!`), or Neovim answered a call with an
    # error. *reason* says which. Not emitted by `Neovim::Handler#detach`, nor
    # when Neovim exits (`Event::ProcessExited`).
    event ViDetached, reason : String
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
    #   never sent back. A change made while Neovim's own are still on their
    #   way waits for them, so neither lands on the wrong lines; where both
    #   changed the same lines, the widget's wins. Another document set on
    #   the widget (`document=`) is followed, its text taken as a reset.
    # * **Undo.** `u` and `Ctrl-R` are Neovim's, with its undo steps (an
    #   insert is one); the widget's mirror of each change is an undo step of
    #   the widget too, so an application's own Undo still works on the
    #   widget, and what it undoes reaches Neovim as an outside change. A
    #   reset of the widget's document (`value=` on a `Widget::TextEdit` or
    #   `Widget::PlainTextEdit`, `TextDocument#set_plain_text`), which clears
    #   its undo stack, clears Neovim's undo history too.
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
    #   Neovim: `:w`, `:up`, `:saveas` and the writes of `:wq`, `:x` and `ZZ`
    #   emit `Event::ViWriteRequested`, `:q`, `:qa`, `:wq`, `:x`, `ZZ` and `ZQ`
    #   emit `Event::ViQuitRequested` (FakeVim's `writeAllRequested`,
    #   `quitRequested`), and Neovim keeps running.
    # * **One buffer, one window.** Neovim's window keeps the widget's
    #   buffer: another put there (`:enew`, `:e FILE`, `:b N`) or another
    #   window entered (`:split`, `:new`) is left again at once, with an
    #   error message, so the keys keep editing what the widget shows.
    # * **Several views.** Other widgets showing the same `TextDocument` can
    #   be added as views of the buffer (`#add_view`), as Vim shows one buffer
    #   in several windows: the keys and pastes of each go to the one buffer,
    #   the view whose key, paste or focus came last is `#active_widget`,
    #   whose caret Neovim's cursor and whose size Neovim's window follow,
    #   and the mode's caret shape is every view's. The mode, command line
    #   and message events are emitted once, by the handler. A view
    #   destroyed or given another document is removed (`#remove_view`),
    #   the last one detaching; a lone view takes the buffer to its new
    #   document, as before.
    # * **Neovim gone.** When Neovim cannot be started `#attach` returns
    #   false and leaves the widget alone; when it exits, the handler detaches
    #   and emits `Event::ProcessExited`, and when the widget's buffer is
    #   closed in Neovim (`:bwipeout`) or a call to Neovim fails or goes
    #   unanswered for `#request_timeout`, it detaches and emits
    #   `Event::ViDetached`. Either way the widget edits as it does without
    #   one. `Ctrl-C` goes to Neovim at once, to interrupt it.
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

      # How long a call that Neovim must answer before the handler goes on
      # (sending a change of the widget's text, a paste, a buffer switch)
      # waits. A Neovim busy for longer — a loop, a long `:!cmd`, both of
      # which `Ctrl-C` interrupts, or a hang — is let go of with
      # `Event::ViDetached` rather than holding up the application.
      property request_timeout : Time::Span = 5.seconds

      # Whether the caret's shape follows the mode (see the class docs).
      property? cursor_shapes : Bool = true

      # The widget the handler is attached to, or `nil`. With several views
      # (`#add_view`), the first of `#views`: the one attached to, or, once
      # that one is removed, the oldest view left.
      getter widget : Widget?

      # The active view seen through `Mixin::TextEditing`, with its concrete
      # type (a value typed by the module alone would be its classes' common
      # ancestor to the compiler, which has none of the mixin's methods).
      @target : Target?

      # Every view of the buffer, the attached widget first (`#add_view`).
      @views = [] of Target

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
      # How many changes Neovim has reported of the buffer (`#lines_changed`):
      # a change of the widget is taken by Neovim only on top of all of them
      # (`#push_text`), as vscode-neovim matches `b:changedtick`.
      @version = 0_i64
      @owns_client = false
      @subs = ::Crysterm::Subscriptions.new
      @notification : Client::NotificationHandler?

      # The `Client#on_exit` block `#setup` added, removed by `#teardown`.
      @exit_handler : Client::ExitHandler?

      # Set while the handler itself changes the widget, whose events are
      # then no outside change.
      @applying = false
      @text_dirty = false
      # Set when the widget's document was reset (`set_plain_text`, which
      # clears its undo stack): Neovim's undo history goes too.
      @text_reset = false
      @caret_dirty = false
      @flush_scheduled = false
      @seq = 0_i64
      @waiter : {Int64, Channel(Nil)}? = nil
      @mode_dirty = false
      @read_only = false
      # Set during `#setup`, whose failure `#attach` reports by its result
      # rather than by an event.
      @setting_up = false
      # Set when a call was not answered (`#call`): the handler's own Neovim
      # is then ended without the grace a quit is given.
      @hung = false

      # *client* is a Neovim to share (never ended by the handler); without
      # one the handler starts its own at `#attach` with *args*.
      def initialize(@client : Client? = nil, @args : Array(String) = Handler.default_args.dup,
                     @executable : String = Neovim.executable)
      end

      # Whether the handler is attached to a widget.
      def attached? : Bool
        !@widget.nil?
      end

      # The widgets that show the buffer: the one attached to and those added
      # with `#add_view`, oldest first; empty while detached.
      def views : Array(Widget)
        @views.map { |v| v.widget.as(Widget) }
      end

      # The view whose key press, paste or focus came last (the one attached
      # to until another has): the one Neovim's cursor, caret shape and
      # window size follow, and the one an application asks for the editor
      # a `Event::ViWriteRequested` or `Event::ViQuitRequested` came from.
      # `nil` while detached.
      def active_widget : Widget?
        @target.try &.widget
      end

      # Adds *widget* as another view of the buffer, as Vim shows one buffer
      # in several windows: its keys and pastes go to Neovim as the attached
      # widget's do, and the view whose key, paste or focus came last becomes
      # `#active_widget`. *widget* must show the attached widget's
      # `TextDocument` (`document=`), whose edits every view then shows;
      # refused (false) otherwise, or while detached. True also when
      # *widget* is a view already. A view destroyed is removed
      # (`#remove_view`), and so is one given another document, the first
      # included, while others are left.
      def add_view(widget : Mixin::TextEditing) : Bool
        add_view_target TargetOf.new(widget)
      end

      private def add_view_target(target : Target) : Bool
        return false unless (first = @views.first?) && @buffer
        return true if @views.any? &.widget.same?(target.widget)
        doc = target.document
        return false unless doc && (fd = first.document) && doc.same?(fd) && target.single_line? == first.single_line?
        @views << target
        watch_view target
        save_cursor target
        apply_cursor_shape
        true
      end

      # Removes *widget* from the views of the buffer and gives it back its
      # own keys and caret shape. Removing the active view makes the oldest
      # view left active; removing the last detaches (`#detach`).
      def remove_view(widget : Widget) : Nil
        i = @views.index(&.widget.same?(widget)) || return
        if @views.size == 1
          detach
          return
        end
        view = @views.delete_at i
        view.subs.off
        restore_cursor view
        if i == 0
          # The document's changes were followed through this view.
          primary = @views.first
          @widget = primary.widget
          @subs.off
          watch_document primary
        end
        activate @views.first if active?(view)
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
        @setting_up = true
        begin
          setup client, target
        rescue ex : Error
          ::Log.warn { "Crysterm::Neovim::Handler: #{ex.message}" }
          teardown
          return false
        ensure
          @setting_up = false
        end
        # A Neovim that ended during the setup's last step (its first state,
        # which reports a failure by detaching) has left the widget already.
        attached?
      end

      # Gives the widget (and every other view, `#add_view`) back its own key
      # handling: drops the handler's subscriptions, restores the caret's
      # shape, and deletes the buffer from a shared Neovim or ends the
      # handler's own.
      def detach : Nil
        views = @views.dup
        teardown
        views.each { |v| restore_cursor v }
      end

      # Sends *keys*, in Neovim's key notation (`"dd"`, `"<Esc>"`, `":w<CR>"`),
      # as if typed into the widget, and waits until the widget mirrors what
      # they did (at most `#sync_timeout`).
      def input(keys : String) : Nil
        # Detached from a shared Neovim, the handler has the client still,
        # but no buffer: the keys would go to whichever its window shows.
        return unless (client = @client) && @buffer
        if keys == "<C-c>"
          # Neovim takes `Ctrl-C` at once, ahead of the calls it has queued,
          # and stops what it is busy with (a loop, a `:!cmd`): sent without
          # waiting for the lock a call to the busy Neovim may hold.
          client.notify "nvim_input", keys
        else
          exclusive(client) do
            flush_pending
            show_buffer client
            sync_read_only client
            client.notify "nvim_input", keys
          end
        end
        sync
      rescue ex : Error
        gone ex.message
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
        @views = [target] of Target
        @lines, @eol = split_lines target
        @version = 0_i64
        @mode = Mode::Normal
        @command_line = nil
        @message = nil
        @pending_keys = ""
        @read_only = target.read_only?
        client.request "nvim_exec_lua", "crysterm_vi.attach(...)", [buf, target.single_line?, @lines, !@read_only]
        @notification = client.on_notification { |method, params| notified client, method, params }
        @exit_handler = client.on_exit { |code| exited client, code }
        # Under the client's lock, as `#show_buffer`: a handler sharing the
        # Neovim may be between its own buffer switch and its keys.
        exclusive(client) do
          client.request "nvim_exec_lua", "crysterm_vi.show(...)", [buf]
          client.shown_buffer = buf
          begin
            client.request "nvim_ui_attach", *ui_size(widget), {"ext_linegrid" => true, "ext_cmdline" => true, "ext_messages" => true, "rgb" => true}
          rescue Error
            # A shared Neovim has a UI attached already.
          end
          push_caret client, target, Mode::Normal
        end

        watch_view target, document: true
        save_cursor target
        apply_cursor_shape
        request_state wait: true
      end

      # Subscribes to *target*'s events, into its own bag (`Target#subs`); with
      # *document*, also to the document's changes (`#watch_document`), in
      # between, in the order the handler has always subscribed them.
      private def watch_view(target : Target, document : Bool = false) : Nil
        widget = target.widget
        subs = target.subs
        subs.on(widget, ::Crysterm::Event::KeyPress, at: ::EventHandler.at_beginning) { |e| key_pressed target, e }
        subs.on(widget, ::Crysterm::Event::Paste, at: ::EventHandler.at_beginning) { |e| pasted target, e }
        watch_document target if document
        # The caret and selection of the active view only: another view's
        # move with the edits of the document they share.
        subs.on(widget, ::Crysterm::Event::CursorPositionChanged) { outside_change caret: true if active?(target) }
        subs.on(widget, ::Crysterm::Event::SelectionChanged) { outside_change caret: true if active?(target) }
        subs.on(widget, ::Crysterm::Event::FocusIn) { focused target }
        subs.on(widget, ::Crysterm::Event::Resize) { resized if active?(target) }
        subs.auto_dispose(widget) { remove_view widget }
        # Ahead of the document's reset (`#watch_document`), which a view
        # let go of here is spared.
        subs.on(widget, ::Crysterm::Event::DocumentChanged, at: ::EventHandler.at_beginning) { view_document_changed target }
      end

      # Follows the changes of the views' document, through *target* (the
      # first view): once for all views, so an edit made in one is one
      # outside change.
      private def watch_document(target : Target) : Nil
        @subs.on(target.widget, ::Crysterm::Event::TextChanged) { outside_change text: true }
        target.on_document_change(@subs) { |reset| outside_change text: true, reset: reset }
      end

      # *target* was given another document: with other views left, it no
      # longer shows their buffer and is let go of, whichever view it is,
      # the buffer staying with the others; the only view takes the buffer
      # along to its new document (`#watch_document`'s reset).
      private def view_document_changed(target : Target) : Nil
        remove_view target.widget if @views.size > 1
      end

      # Whether *target* is the active view.
      private def active?(target : Target) : Bool
        (t = @target) ? t.same?(target) : false
      end

      # Makes *target* the active view, the one Neovim's cursor follows:
      # its caret is sent to Neovim, as Vim's cursor is the entered window's,
      # and Neovim's window takes its size.
      private def activate(target : Target) : Nil
        return if active?(target)
        @target = target
        outside_change caret: true
        resized
      end

      # Undoes `#setup`, as far as it got.
      private def teardown : Nil
        @subs.off
        @views.each &.subs.off
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
          client.shown_buffer = nil if client.shown_buffer == @buffer
          if @owns_client
            # Let go of the client first: its exit, reported while `#close`
            # waits for it, is then no Neovim ending under the widget
            # (`#exited`), and emits no `Event::ProcessExited`.
            @client = nil
            @hung ? client.close(grace: 100.milliseconds) : client.close
          elsif client.running? && (buf = @buffer)
            client.notify("nvim_buf_delete", buf, {"force" => true}) rescue nil
          end
        end
        @buffer = nil
        @widget = nil
        @target = nil
        @views = [] of Target
        @text_reset = false
        @hung = false
        if w = @waiter
          @waiter = nil
          w[1].send nil
        end
      end

      # Remembers *target*'s own caret shape, given back by `#restore_cursor`.
      private def save_cursor(target : Target) : Nil
        cursor = target.widget.cursor
        target.saved_shape = cursor.try &.shape
        target.saved_blink = cursor.try(&.blink) || false
      end

      private def restore_cursor(target : Target) : Nil
        return unless @cursor_shapes
        widget = target.widget
        if shape = target.saved_shape
          widget.set_cursor shape, blink: target.saved_blink
        else
          widget.reset_cursor
        end
        target.saved_shape = nil
      end

      # The client's Neovim exited: the widget is on its own again.
      private def exited(client : Client, code : Int32?) : Nil
        return unless client.same?(@client) && attached?
        detach
        emit ::Crysterm::Event::ProcessExited, code unless @setting_up
      end

      # Neovim cannot be worked with any more, for *reason*: the handler
      # detaches and says so — as `#exited` does when Neovim turns out to
      # have exited, which its exit, still to be reported, no longer will.
      private def gone(reason : String?) : Nil
        return unless attached?
        client = @client
        running = client.try &.running?
        detach
        # `#attach` says so itself, by returning false.
        return if @setting_up
        if client && !running
          emit ::Crysterm::Event::ProcessExited, client.exit_code
        else
          emit ::Crysterm::Event::ViDetached, reason || "Neovim failed"
        end
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

      private def key_pressed(target : Target, e : ::Crysterm::Event::KeyPress) : Nil
        return if e.accepted?
        return unless @target
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
        activate target
        input keys
      end

      private def pasted(target : Target, e : ::Crysterm::Event::Paste) : Nil
        return if e.accepted?
        client = @client || return
        return if target.read_only?
        e.accept
        activate target
        exclusive(client) do
          flush_pending
          show_buffer client
          call client, "nvim_paste", e.content, true, -1
        end
        sync
      rescue ex : Error
        gone ex.message
      end

      # Makes the widget's buffer the one in Neovim's window, for a shared
      # Neovim whose window showed another handler's.
      private def show_buffer(client : Client) : Nil
        buf = @buffer || return
        return if client.shown_buffer == buf
        client.shown_buffer = buf
        call client, "nvim_exec_lua", "crysterm_vi.show(...)", [buf]
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
        call client, "nvim_exec_lua", "vim.bo[...].modifiable = select(2, ...)", [buf, !ro]
      end

      # Calls *method* in Neovim and returns its answer, as `Client#request`
      # does, within `#request_timeout`.
      private def call(client : Client, method : String, *params) : MessagePack::Any
        client.request_with method, params, @request_timeout
      rescue TimeoutError
        @hung = true
        raise Error.new "Neovim did not answer within #{@request_timeout.total_seconds.format(decimal_places: 1, only_significant: true)} s"
      end

      private def focused(target : Target) : Nil
        activate target
        apply_cursor_shape
        if c = @client
          exclusive(c) { show_buffer c }
        end
      rescue ex : Error
        gone ex.message
      end

      private def resized : Nil
        return unless (c = @client) && (w = active_widget) && c.shown_buffer == @buffer
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
      rescue ex : Error
        gone ex.message
      end

      # Neovim's notifications, on the client's dispatch fiber, in order.
      private def notified(client : Client, method : String, params : Array(MessagePack::Type)) : Nil
        return unless client.same?(@client)
        buf = @buffer || return
        case method
        when "crysterm_vi_lines"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          # Not while a change of the widget is on its way to Neovim
          # (`#push_text`), which is taken on top of this one or not at all.
          exclusive(client) do
            next unless @buffer == buf
            lines_changed params[1].as(Int).to_i64, params[2].as(Int).to_i32,
              params[3].as(Int).to_i32, params[4].as(Array).map(&.to_s)
          end
        when "crysterm_vi_state"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          state_received params
        when "crysterm_vi_write"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          emit ::Crysterm::Event::ViWriteRequested, params[1]?.as?(String), params[2]? == true, params[3]? == true
        when "crysterm_vi_quit"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          emit ::Crysterm::Event::ViQuitRequested, params[1]? == true, params[2]? == true
        when "crysterm_vi_detach"
          return unless params[0]?.as?(Int).try(&.to_i64) == buf
          gone "The buffer was closed in Neovim"
        when "redraw"
          redraw params if client.shown_buffer == buf
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
        shape =
          case @mode
          when .insert?, .command_line?      then ::Tput::CursorShape::Line
          when .replace?, .operator_pending? then ::Tput::CursorShape::Underline
          else                                    ::Tput::CursorShape::Block
          end
        @views.each do |view|
          widget = view.widget
          widget.set_cursor shape unless widget.cursor_shape == shape
        end
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
            cur = Math.min(char_end(row, col), target.buf_size)
          else
            anchor = Math.min(char_end(vrow, vcol), target.buf_size)
          end
        end
        applying { target.set_caret cur, anchor }
      end

      private def line_at(row : Int32) : String
        @lines[row.clamp(0, @lines.size - 1)]
      end

      # The widget position of line *row*'s start, in the text of *lines*.
      private def line_offset(row : Int32, lines : Array(String) = @lines) : Int32
        row = row.clamp(0, lines.size)
        off = 0
        row.times { |i| off += lines[i].size + 1 }
        off
      end

      # The widget position of byte column *col* on line *row*.
      private def flat_position(row : Int32, col : Int32) : Int32
        line = line_at(row)
        line_offset(row.clamp(0, @lines.size - 1)) + char_column(line, col)
      end

      # The widget position just past the character at byte column *col* of
      # line *row*, the end of a Visual selection: a whole grapheme cluster
      # (a letter with its combining marks, a flag), which Neovim selects as
      # one character, or past the line's end, its line break.
      private def char_end(row : Int32, col : Int32) : Int32
        line = line_at(row)
        size = 1
        if 0 <= col < line.bytesize
          line.byte_slice(col).each_grapheme { |g| size = g.size; break }
        end
        flat_position(row, col) + size
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

      # Neovim replaced lines *first*...*last* of its buffer with *data*, its
      # change number *version*: the same lines of the widget's text get the
      # smallest edit that makes them so. Under the client's lock.
      #
      # A change of the widget not yet in Neovim, which `#push_text` sends
      # once Neovim's are in, is kept: Neovim's change goes where its lines
      # are in the widget, before or after the lines the widget changed.
      # One that overlaps those is left out of the widget, whose change then
      # replaces it in Neovim too; so is every change before a reset of the
      # widget's document, which replaces all of Neovim's lines.
      private def lines_changed(version : Int64, first : Int32, last : Int32, data : Array(String)) : Nil
        target = @target || return
        # Reported before a reset of the buffer, which replaced it.
        return if version <= @version
        @version = version
        n = @lines.size
        first = first.clamp(0, n)
        last = last.clamp(first, n)
        lines, eol, at = @lines, @eol, first
        if @text_dirty
          schedule_flush
          keep = false
          unless @text_reset
            lines, eol = split_lines target
            p, q = common_ends(@lines, lines)
            if last <= p
              keep = true
            elsif first >= n - q
              keep = true
              at = first + lines.size - n
            end
          end
          unless keep
            @lines[first...last] = data
            @lines << "" if @lines.empty?
            return
          end
        end
        edit = widget_edit target, lines, eol, at, at + last - first, data
        @lines[first...last] = data
        @lines << "" if @lines.empty?
        # Out of step (an edit the handler did not see): the widget takes
        # Neovim's whole text.
        s, e, ins = edit || {0, target.buf_size, joined_lines(separator)}
        replace target, s, e, ins
      end

      # The widget's range and the text that replace lines *first*...*last*
      # of *lines* with *data*, in the text the lines make (followed by a
      # newline with *eol*); `nil` when the widget's text is not that text.
      private def widget_edit(target : Target, lines : Array(String), eol : Bool, first : Int32, last : Int32,
                              data : Array(String)) : {Int32, Int32, String}?
        sep = separator
        n = lines.size
        total = line_offset(n, lines) - 1
        a = line_offset(first, lines)
        old = lines[first...last]
        new_text = data.join(sep)
        edit =
          if !old.empty? && !data.empty?
            {a, a + old.join(sep).size, new_text}
          elsif old.empty? && !data.empty?
            first < n ? {a, a, new_text + sep} : {total, total, sep + new_text}
          elsif !old.empty?
            if last < n
              {a, a + old.join(sep).size + 1, ""}
            elsif first > 0
              {a - 1, total, ""}
            else
              {0, total, ""}
            end
          else
            return {0, 0, ""}
          end
        edit if target.buf_size == total + (eol ? 1 : 0)
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
      private def outside_change(text : Bool = false, caret : Bool = false, reset : Bool = false) : Nil
        return if @applying
        @text_dirty ||= text
        @text_reset ||= reset
        @caret_dirty ||= caret
        schedule_flush
      end

      private def schedule_flush : Nil
        return if @flush_scheduled
        @flush_scheduled = true
        spawn(name: "Neovim::Handler flush") { flush_external }
      end

      private def flush_external : Nil
        @flush_scheduled = false
        client = @client || return
        exclusive(client) { flush_pending }
      rescue ex : Error
        gone ex.message
      end

      # Holds *client*'s lock (`Client#handler_lock`) for the block, while a
      # handler sends Neovim a change and then keys. `nvim_input` is a fast
      # call: its keys reach Neovim's typeahead at once, ahead of a call sent
      # before them still waiting in Neovim's event queue (a buffer switch,
      # the widget's lines). So such a call is a request, its answer awaited
      # before any key is sent, and the lock keeps a handler sharing the
      # client from sending keys meanwhile.
      private def exclusive(client : Client, &)
        client.handler_lock.synchronize { yield }
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
          # Refused: sent again once Neovim's changes are in (the caret
          # then too, which is placed on the lines with the change).
          return unless push_text client, target
        end
        if @caret_dirty
          @caret_dirty = false
          if client.shown_buffer == @buffer
            push_caret client, target, @mode
            request_state wait: false
          end
        end
      end

      # Sends Neovim the lines that differ between its buffer and the widget;
      # after a reset of the widget's document, all of them, with Neovim's
      # undo history cleared as the widget's was, so `u` cannot bring back
      # the text from before (another file's). Returns false, with the
      # change still to send, when Neovim has changed its buffer since the
      # last change the handler took in (`#lines_changed`, which takes those
      # in and sends this again), as the lines would land in the wrong place.
      private def push_text(client : Client, target : Target) : Bool
        buf = @buffer || return true
        new, eol = split_lines target
        old = @lines
        if @text_reset
          @text_reset = false
          @version = call(client, "nvim_exec_lua", "return crysterm_vi.reset(...)", [buf, new]).as_i64
        elsif new != old
          p, q = common_ends(old, new)
          unless call(client, "nvim_exec_lua", "return crysterm_vi.set_lines(...)", [buf, @version, p, old.size - q, new[p...(new.size - q)]]).as_bool
            @text_dirty = true
            return false
          end
        end
        @lines, @eol = new, eol
        true
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
        # The handler's subscriptions to this view's events.
        getter subs = ::Crysterm::Subscriptions.new
        # The view's own caret shape, given back when the handler lets go.
        property saved_shape : ::Tput::CursorShape? = nil
        property saved_blink : Bool = false

        abstract def widget : Widget
        # The document the widget shows, for a widget with one
        # (`Mixin::TextEditing::DocumentBuffer`).
        abstract def document : TextDocument?
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
        # by a `TextCursor` tell no `Event::TextChanged`; *block* is told
        # whether the change reset the document (`TextDocument#set_plain_text`,
        # or another document set on the widget).
        abstract def on_document_change(subs : ::Crysterm::Subscriptions, &block : Bool ->) : Nil
      end

      private class TargetOf(W) < Target
        def initialize(@w : W)
        end

        def widget : Widget
          @w
        end

        def document : TextDocument?
          w = @w
          w.document if w.is_a?(Mixin::TextEditing::DocumentBuffer)
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

        def on_document_change(subs : ::Crysterm::Subscriptions, &block : Bool ->) : Nil
          w = @w
          if w.is_a?(Mixin::TextEditing::DocumentBuffer)
            doc = subs.on(w.document, ::Crysterm::Event::ContentsChanged) { |e| block.call e.kind.replace? }
            # Another document set on the widget: its changes are followed
            # instead, and its text replaces the old one's as a reset.
            subs.on(w, ::Crysterm::Event::DocumentChanged) do |e|
              # Not once *subs* was let go of during this very event (the
              # handler dropping the view): re-armed, *doc* would outlive
              # the bag.
              next unless doc.active?
              doc.on(e.document, ::Crysterm::Event::ContentsChanged) { |c| block.call c.kind.replace? }
              block.call true
            end
          end
        end
      end

      # The Lua side, run once per attach (idempotent): `crysterm_vi.attach`
      # sets a buffer up, `show` puts one in Neovim's window, `state`
      # answers with the mode and cursor, and `set_lines` takes the widget's
      # changes without sending them back.
      LUA = <<-LUA
        local chan = ...
        local C = _G.crysterm_vi or { quiet = {} }
        _G.crysterm_vi = C
        C.chan = chan
        vim.o.hidden = true
        vim.o.more = false
        vim.o.swapfile = false

        -- The changes of a buffer not yet sent, as one: lines `first` to
        -- `last` (0-based, exclusive) as the handler has them are now
        -- `first` to `new_last`. Neovim reports some commands line by line
        -- (an undo of `:%s`, `:g`), which as many notifications, each an
        -- edit and an undo step of the widget, took minutes on a long
        -- document; they go as one when Neovim is next idle, or before
        -- anything else is sent about the buffer.
        C.pending = C.pending or {}

        -- How many changes of a buffer were sent: the handler sends its own
        -- with the number it has taken in, and one sent before Neovim's
        -- latest are in would be put on the wrong lines (`C.set_lines`).
        C.version = C.version or {}

        function C.flush(buf)
          local p = C.pending[buf]
          if not p then return end
          C.pending[buf] = nil
          if not vim.api.nvim_buf_is_loaded(buf) then return end
          local v = (C.version[buf] or 0) + 1
          C.version[buf] = v
          vim.rpcnotify(C.chan, 'crysterm_vi_lines', buf, v, p.first, p.last, vim.api.nvim_buf_get_lines(buf, p.first, p.new_last, false))
        end

        local function changed(buf, first, last, new_last)
          local p = C.pending[buf]
          if not p then
            C.pending[buf] = { first = first, last = last, new_last = new_last }
            vim.schedule(function() C.flush(buf) end)
            return
          end
          -- Lines before the pending change are where they were; lines
          -- after it are moved by its count.
          if last > p.new_last then
            p.last = p.last + last - p.new_last
            p.new_last = new_last
          else
            p.new_last = p.new_last + new_last - last
          end
          p.first = math.min(p.first, first)
        end

        local function quit(bang, all, write)
          local buf = vim.api.nvim_get_current_buf()
          if write == 'write' then
            vim.cmd(bang and 'write!' or 'write')
          elseif write == 'update' then
            vim.cmd('update')
          end
          C.flush(buf)
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

        -- The window the handlers show their buffers in, and the buffer it
        -- shows. Another buffer put there from Neovim (`:enew`, `:e FILE`,
        -- `:b N`), or another window entered (`:split`, `:new`), would take
        -- the keys of a widget still mirroring its own: the window and its
        -- buffer come back, as the handler's `show_buffer` would bring the
        -- buffer before its next key, and an error says why. The other
        -- windows (not floating ones) are closed, as the widget shows none
        -- of them, and a file buffer they or the window showed is wiped
        -- unless modified, a handler's (`C.own`) or still in a window, so
        -- that no hidden buffer is left for `:bufdo` or `:wall` to change.
        C.own = C.own or {}

        function C.show(buf)
          C.win = vim.api.nvim_get_current_win()
          C.shown = buf
          vim.api.nvim_win_set_buf(C.win, buf)
        end

        local function restore()
          local buf = C.shown
          if not (buf and vim.api.nvim_buf_is_loaded(buf)) or vim.fn.getcmdwintype() ~= '' then return end
          local cur = vim.api.nvim_get_current_win()
          if not (C.win and vim.api.nvim_win_is_valid(C.win)) then C.win = cur end
          local left = {}
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            if w ~= C.win and vim.api.nvim_win_get_config(w).relative == '' then
              left[vim.api.nvim_win_get_buf(w)] = true
              pcall(vim.api.nvim_win_close, w, false)
            end
          end
          local was = vim.api.nvim_win_get_buf(C.win)
          if cur == C.win and was == buf and next(left) == nil then return end
          left[was] = true
          if pcall(vim.api.nvim_set_current_win, C.win) and pcall(vim.api.nvim_win_set_buf, C.win, buf) then
            vim.api.nvim_echo({ { "Only the widget's own buffer can be edited here" } }, true, { err = true })
          end
          for b in pairs(left) do
            if not C.own[b] and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == ''
                and not vim.bo[b].modified and #vim.fn.win_findbuf(b) == 0 then
              pcall(vim.api.nvim_buf_delete, b, {})
            end
          end
        end
        -- Run when Neovim next handles its events, out of the command that
        -- switched (`:e FILE | s/a/b/` edits FILE), and at the latest by
        -- `C.state`, which the handler waits for before its next keys:
        -- those reach Neovim's typeahead ahead of the events, and would
        -- otherwise edit the other buffer.
        function C.restore_if_due()
          if not C.restore_due then return end
          C.restore_due = nil
          restore()
        end
        vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
          group = vim.api.nvim_create_augroup('crysterm_vi', { clear = true }),
          callback = function()
            if C.restore_due then return end
            C.restore_due = true
            vim.schedule(C.restore_if_due)
          end,
        })

        -- The widget's lines, also into a buffer made read-only for a
        -- read-only widget, whose text the application still sets; refused
        -- (false) unless the handler has taken in `version` changes, every
        -- one sent, when it gives one.
        function C.set_lines(buf, version, first, last, lines)
          C.flush(buf)
          if version and version ~= (C.version[buf] or 0) then return false end
          local bo = vim.bo[buf]
          local modifiable = bo.modifiable
          C.quiet[buf] = true
          bo.modifiable = true
          local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, first, last, false, lines)
          bo.modifiable = modifiable
          C.quiet[buf] = nil
          if not ok then error(err) end
          return true
        end

        -- All of the widget's lines, with no undo history before them;
        -- returns the number of changes sent, which they replace.
        function C.reset(buf, lines)
          local bo = vim.bo[buf]
          local undolevels = bo.undolevels
          bo.undolevels = -1
          local ok, err = pcall(C.set_lines, buf, nil, 0, -1, lines)
          bo.undolevels = undolevels
          bo.modified = false
          if not ok then error(err) end
          return C.version[buf] or 0
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

        -- Names a buffer was given (`:saveas`, `:file`), for its next write.
        C.renamed = C.renamed or {}

        -- Wipes the buffers other than `buf` named `name` that hold nothing.
        local function wipe_named(name, buf)
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if b ~= buf and not C.own[b] and not vim.bo[b].modified and vim.api.nvim_buf_get_name(b) == name then
              pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
          end
        end

        function C.attach(buf, single, lines, modifiable)
          C.own[buf] = true
          C.version[buf] = 0
          C.renamed[buf] = nil
          local bo = vim.bo[buf]
          bo.swapfile = false
          bo.buftype = 'acwrite'
          bo.bufhidden = 'hide'
          local name = 'crysterm://' .. buf
          vim.api.nvim_buf_set_name(buf, name)
          C.reset(buf, lines)
          bo.modifiable = modifiable
          vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, b, _, first, last, new_last)
              if not C.quiet[b] then changed(b, first, last, new_last) end
            end,
            -- Unloaded (`:bwipeout`, `:bdelete`, `:edit!`): its lines are
            -- no longer reported, so the handler lets go of it.
            on_detach = function(_, b)
              C.own[b] = nil
              C.pending[b] = nil
              C.version[b] = nil
              C.renamed[b] = nil
              vim.rpcnotify(C.chan, 'crysterm_vi_detach', b)
            end,
          })
          -- Named another file (`:saveas FILE`, `:file FILE`): the buffer
          -- keeps the name the handler knows it by, the alternate buffers
          -- the two names leave are wiped, and its next write (`:saveas`'s
          -- own) asks the application to save under the new name.
          vim.api.nvim_create_autocmd('BufFilePost', {
            buffer = buf,
            callback = function()
              local new = vim.api.nvim_buf_get_name(buf)
              if new == name then return end
              if new ~= '' then C.renamed[buf] = new end
              wipe_named(name, buf)
              vim.api.nvim_buf_set_name(buf, name)
              wipe_named(new, buf)
            end,
          })
          -- A write to the buffer's own name is the application's save
          -- (under a name given since, a Save As); another name (`:w FILE`)
          -- is a copy, after which the buffer is still modified, as in Vim.
          vim.api.nvim_create_autocmd('BufWriteCmd', {
            buffer = buf,
            callback = function(a)
              local path, rename = a.match, false
              if path == name then
                path, rename = C.renamed[buf] or vim.NIL, C.renamed[buf] ~= nil
                C.renamed[buf] = nil
                vim.bo[buf].modified = false
              end
              C.flush(buf)
              vim.rpcnotify(C.chan, 'crysterm_vi_write', buf, path, vim.v.cmdbang == 1, rename)
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
          C.restore_if_due()
          C.flush(buf)
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
