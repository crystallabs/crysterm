require "./index_validation"
require "./nav_keys"

module Crysterm
  module Mixin
    # The "horizontal bar of selectable commands" concern: a command model,
    # left-to-right layout, keyboard navigation, hotkeys, and rendering.
    #
    # Qt makes `QMenuBar` and `QToolBar` siblings under `QWidget`, not under a
    # shared "bar" class; Crysterm mirrors that by sharing the bar behavior as a
    # module rather than a base class. An including widget derives `Box` and calls
    # `setup_action_bar` from `initialize` (after `super`) to wire the
    # keyboard/focus handlers.
    module ActionBar
      # For the `#<<`/`#>>` operator aliases below. `Widget` includes this too, but
      # a standalone module doesn't inherit macros from its future includers.
      include Crystallabs::Helpers::Alias_Methods
      include IndexValidation

      # A single command/tab shown in an action bar.
      class Command
        # Text shown after the (optional) prefix.
        property text : String

        # Prefix shown before `text` (e.g. the auto-generated `1`, `2`, ...).
        # `nil` means no prefix is rendered.
        property prefix : String?

        # Whether `#prefix` was auto-generated (the `N:` position number) rather
        # than set explicitly or derived from a hotkey. Only auto prefixes are
        # renumbered when a sibling is removed, so the shown `N:` labels stay in
        # step with the raw index number-key selection uses.
        property? auto_prefix = false

        # Invoked when the command is triggered (Enter / click / hotkey).
        property callback : Proc(Nil)?

        # Per-command global hotkeys (matched against the pressed character).
        # When set, the first entry also becomes the displayed `prefix`.
        property keys : Array(String)?

        # The `Box` rendering this command, assigned by `#add_item`.
        property widget : Widget::Box?

        # Computed display width of this command's box.
        property width : Int32 = 0

        # Whether this is a non-selectable visual separator rather than a real
        # command (Qt's `QToolBar#addSeparator`).
        property? separator = false

        # Widget embedded in this item instead of a label (`ToolBar#add_widget`,
        # Qt's `QToolBar#addWidget` / `QWidgetAction`). It is hosted *inside*
        # `#widget`, the box that reserves the item's strip cells; `nil` for an
        # ordinary command.
        property embedded : Widget?

        # Whether this item hosts an embedded widget rather than a label.
        def embedded? : Bool
          !@embedded.nil?
        end

        # Whether this command takes part in selection and keyboard navigation.
        # False for separators (nothing to select) and for embedded widgets,
        # which run their own focus/key handling — see `ToolBar#add_widget`.
        def selectable? : Bool
          !separator? && !embedded?
        end

        # Window-level subscription for this command's global hotkeys (`#keys`).
        # A `Subscription` captures the *window it was installed on* at subscribe
        # time, so `#off` removes it from that exact window regardless of the
        # bar's later `window?` — no leak after a reparent/detach.
        property key_handler : ::Crysterm::Subscription?

        def initialize(@text, @callback = nil, *, @prefix = nil, @keys = nil)
        end
      end

      # Backing per-command `Box` widgets, one per command, parallel to
      # `#commands`/`@ritems`. The render/geometry store the bar mutates; the
      # public *model* is `#items` (the commands). Lives here, not on the
      # `Widget` base, so only bars carry it.
      property item_boxes = [] of Widget::Box

      @ritems = [] of String

      # Tag-stripped command texts, parallel to `#item_boxes`. Read-only view;
      # the bar rebuilds it internally as commands are added/removed.
      def item_texts : Array(String)
        @ritems
      end

      # The bar's item model: its `Command`s, in order. Symmetric with the
      # `#items=(Array(Command))` setter, so `bar.items += [cmd]` reads, appends
      # and writes back end-to-end. This is the model, NOT the backing `Box`
      # widgets — those are `#item_boxes`. `#commands` is the same array under its
      # domain name.
      def items : Array(Command)
        @commands
      end

      # The commands, parallel to `#item_boxes`. Same array as `#items` under its
      # domain name.
      getter commands = [] of Command

      # Index of the left-most fully-visible item (for horizontal scrolling).
      getter left_base = 0
      protected setter left_base

      # Offset of the selected item relative to `#left_base`.
      getter left_offset = 0
      protected setter left_offset

      # React to mouse clicks on items?
      property? mouse = false

      # Select commands with the number keys `1`..`9`/`0`?
      property? auto_command_keys = false

      # Prefix each command with an auto-generated `N:` label. Turn off for a plain
      # bar of labels.
      property? auto_prefix = true

      # Inert cells between adjacent item boxes (no leading gap, so inert cells
      # fall only after the last item). Defaults to 2. Set 0 to pack items flush —
      # each item box already carries its own side padding (`width = text + 2`), so
      # that still leaves breathing room.
      property item_gap : Int32 = 2

      # Wires the keyboard navigation and focus re-selection handlers, and sets the
      # bar's interaction defaults. Call from `initialize` after `super`;
      # `mouse`/`auto_prefix` default to the widget's existing values.
      private def setup_action_bar(mouse = @mouse, auto_prefix = @auto_prefix) : Nil
        @mouse = mouse
        @auto_prefix = auto_prefix

        if @keys
          on ::Crysterm::Event::KeyPress, ->handle_key_press(::Crysterm::Event::KeyPress)
        end

        # `auto_command_keys` (number-key selection) is handled in the
        # widget-local `#handle_key_press` rather than a global `window.on`: number
        # keys must not be hijacked while unfocused (would collide with numeric
        # input elsewhere), and a widget-local handler is torn down with the
        # widget instead of leaking on the window.

        on(::Crysterm::Event::FocusIn) { self.current_index = current_index }

        # Command hotkeys are window-level accelerators, so they must be tied to
        # the window lifecycle: (re)install on attach, uninstall on detach.
        # Otherwise a bar that merely `remove`s leaves its hotkeys firing on a
        # window it's no longer on, and one added while detached never installs.
        on(::Crysterm::Event::Attached) { install_command_hotkeys }
        on(::Crysterm::Event::Detached) { uninstall_command_hotkeys }
      end

      # Currently-selected absolute index (Qt's `currentIndex`).
      def current_index : Int32
        @left_base + @left_offset
      end

      # Makes the item at *index* the current one, adjusting the horizontal scroll
      # window so it is visible, and emits `Event::ItemSelected`. Selection only —
      # it never runs the command (see `#select_item`/`#trigger`).
      def current_index=(index : Int) : Nil
        if index < 0
          index = 0
        elsif index >= @item_boxes.size
          index = @item_boxes.size - 1
        end

        el = @item_boxes[index]?

        # Keep every item box's state in sync with the new selection so it renders
        # with `styles.selected`. Routed through `#highlight_item?` so a bar with
        # its own highlight semantics inherits the re-highlight without overriding
        # this setter.
        reapply_highlight index

        # The horizontal-scroll math below needs a real layout. Gate on `@lpos`
        # (set after the first render), NOT on `#parent`: a top-level widget
        # appended to a `Window` has no parent, which would skip the scroll update
        # for every window-level bar and freeze the current index at 0. The public
        # `#last_rendered_position` raises when unrendered, so it can't be used as
        # a predicate here.
        #
        # Also gate on `#window?`: `@lpos` survives detach, so on the teardown
        # path (a bar removing items while its window is being destroyed) it is
        # non-nil while the widget is already detached, and the `#awidth` below
        # would then raise (`#window` `not_nil!`). No window ⇒ no layout to do.
        unless @lpos && window?
          # Before the first render (or once detached) there's no layout for the
          # horizontal-scroll math, but the current index (== `@left_base +
          # @left_offset`) must still move to *index* — otherwise the highlight/
          # `ItemSelected` point at *index* while Enter (`fire current_index`)
          # fires the old command.
          el.try do |e|
            @left_base = 0
            @left_offset = index
            emit ::Crysterm::Event::ItemSelected, e, index
          end
          return
        end

        return unless el

        width = (awidth || 0) - ihorizontal
        drawn = 0
        visible = 0
        @item_boxes.each_with_index do |item, i|
          next if i < @left_base
          w = item.awidth || 0
          next if w <= 0
          drawn += w + item_gap
          visible += 1 if drawn <= width
        end

        diff = index - (@left_base + @left_offset)
        if index > @left_base + @left_offset
          if index > @left_base + visible - 1
            @left_offset = 0
            @left_base = index
          else
            @left_offset += diff
          end
        elsif index < @left_base + @left_offset
          diff = -diff
          if index < @left_base
            @left_offset = 0
            @left_base = index
          else
            @left_offset -= diff
          end
        end

        emit ::Crysterm::Event::ItemSelected, el, index
      end

      # Number of commands on the bar, separators included (Qt's
      # `QListWidget#count`).
      def count : Int32
        @commands.size
      end

      # (Re)defines the full set of commands from an array of `Command`s or
      # plain strings.
      def items=(commands : Array(Command))
        @item_boxes.each &.detach_from_tree
        @commands.each { |cmd| release_command cmd }
        @item_boxes.clear
        @ritems.clear
        @commands.clear

        commands.each { |cmd| add_item cmd }

        emit ::Crysterm::Event::ItemsChanged
      end

      # :ditto:
      def items=(commands : Array(String))
        self.items = commands.map { |text| Command.new text }
      end

      # Removes every command (Qt's `QListWidget#clear`).
      def clear
        self.items = [] of Command
      end

      # Appends a command given as plain text plus optional callback/hotkeys.
      #
      # The block overload below is the preferred way to attach an action; the
      # positional `callback` `Proc` param is kept mainly for forwarding an
      # already-built `Proc`.
      def add_item(text : String, callback : Proc(Nil)? = nil, *, keys : Array(String)? = nil)
        add_item Command.new text, callback, keys: keys
      end

      # :ditto:
      #
      # Preferred over passing a positional `Proc`: `bar.add_item("Quit") { ... }`.
      def add_item(text : String, *, keys : Array(String)? = nil, &callback : -> Nil)
        add_item Command.new text, callback, keys: keys
      end

      # Appends a non-selectable separator and returns its `Command` (Qt's
      # `QToolBar#addSeparator`, which likewise hands back the `QAction` so the
      # separator can be hidden/removed later). Default char comes from the
      # `Glyphs` registry at the effective tier.
      def add_separator(char : String? = nil) : Command
        cmd = Command.new(char || glyph(Glyphs::Role::LineVertical).to_s)
        cmd.separator = true
        add_item cmd
        cmd
      end

      # Appends a command hosting *widget* instead of a label and returns its
      # `Command` — the plumbing behind `ToolBar#add_widget` (Qt's
      # `QToolBar#addWidget`), where the semantics are documented.
      #
      # *width* overrides the cells reserved for it; the reservation is stored on
      # the `Command` up front because `#add_item` sizes the host box from
      # `cmd.width` *before* the widget is reparented into it.
      private def add_embedded_item(widget : Widget, width : Int32? = nil) : Command
        cmd = Command.new ""
        cmd.embedded = widget
        cmd.width = width || embedded_width(widget)
        add_item cmd
        cmd
      end

      # Cells to reserve for an embedded widget: its own fixed cell width when it
      # has one, else whatever it currently resolves to (`#awidth` is safe on an
      # unparented widget — it falls back to the global window). Floored at 1, so
      # a widget that resolves to nothing still gets a slot rather than
      # collapsing the row.
      private def embedded_width(widget : Widget) : Int32
        w = widget.width
        n = w.is_a?(Int32) ? w : widget.awidth
        n > 0 ? n : 1
      end

      # Appends a `Command`.
      def add_item(cmd : Command)
        # Pack each item flush after the ones already added: its left is the sum of
        # their widths plus `item_gap` between each, no leading gap. Built from
        # stored command widths (relative to the bar), so it's correct before the
        # bar is parented/rendered.
        drawn = @commands.sum(&.width) + item_gap * @commands.size

        if cmd.selectable?
          # Auto prefixes are position numbers, so a command re-added at a new
          # position (`items=` reorder/filter, remove + re-add) must be
          # renumbered — number-key selection routes by raw index, and a stale
          # baked-in number would point its label at the wrong key. Only
          # explicit/hotkey-derived prefixes (`auto_prefix?` false) survive a
          # re-add unchanged.
          if auto_prefix? && (cmd.prefix.nil? || cmd.auto_prefix?)
            cmd.prefix = (@item_boxes.size + 1).to_s
            cmd.auto_prefix = true
          end

          # A per-command hotkey doubles as the displayed prefix, and is not an
          # auto prefix — it must not be renumbered.
          cmd.keys.try do |keys|
            if keys[0]?
              cmd.prefix = keys[0]
              cmd.auto_prefix = false
            end
          end
        end
        # Sets `cmd.width` too.
        title = command_title cmd

        item = Widget::Box.new(
          window: window,
          top: 0,
          left: drawn,
          height: 1,
          width: cmd.width,
          content: title,
          align: :center,
          focus_on_click: false,
          parse_tags: true,
        )

        # Each item box renders per its own state: the selected item uses the bar's
        # `selected` style, others the `item` style. Both MUST be `dup`ed:
        # `Style#item` falls back to `self`, so every item would otherwise share
        # one `Style` instance — and `Widget#hide`/`#show` mutate
        # `state_style.visible` in place, so the render scroll loop would toggle a
        # single shared flag and never hide scrolled-off items.
        item.styles.normal = style.item.dup
        item.styles.selected = styles.selected.dup

        cmd.widget = item
        @ritems.push clean_tags cmd.text
        @item_boxes.push item
        @commands.push cmd
        append item

        # An embedded widget (`ToolBar#add_widget`) lives *inside* its host item
        # box: the host reserves the strip cells and carries the widget along as
        # the row re-packs, while the widget keeps its own size, style and
        # focus/key handling. Pinned to the host's content origin; a re-add
        # (`items=` reorder) simply re-hosts it under the new box.
        cmd.embedded.try do |w|
          w.top = 0
          w.left = 0
          item.append w
        end

        # Per-command hotkeys are global accelerators (fire regardless of focus).
        # Installed only when the bar is attached; the `Event::Attached` handler
        # re-covers commands added while detached.
        install_command_hotkey cmd

        # No click-to-trigger over a separator, nor over an embedded widget —
        # the latter handles its own clicks, and a host-level handler would fire
        # a command the user never asked for on top of them.
        if @mouse && cmd.selectable?
          item.on(::Crysterm::Event::Click) do
            trigger cmd
          end
        end

        # Auto-select the first *selectable* command — testing `@item_boxes.size == 1`
        # instead would leave a bar opening with a leading `add_separator` stuck on
        # the non-selectable separator. `@left_base`/`@left_offset` (selected ==
        # their sum) are set directly rather than via `#current_index=`, whose
        # window math is gated on a laid-out `@lpos` and can't move the index before
        # the first render. `@left_base` stays 0 so every command, separators
        # included, remains visible.
        if cmd.selectable? && @commands.count(&.selectable?) == 1
          @left_base = 0
          @left_offset = @item_boxes.size - 1
          self.current_index = current_index
        end

        emit ::Crysterm::Event::ItemAdded

        item
      end

      # `#<<` is an operator alias for `#add_item`, e.g. `bar << "Quit"`, defined
      # once per `#add_item` overload.
      #
      # NOTE: every `Widget` also includes `Mixin::Children`, whose `#<<(Widget)`
      # appends a *child widget*, and this module sits closer in the ancestor
      # chain than `Widget`. The two coexist only because `alias_method` copies
      # each overload's restrictions: none of `#add_item`'s takes a bare `Widget`,
      # so `bar << some_widget` still resolves to the child-append.
      alias_method :<<, :add_item

      # Fires the command at *index*: emits `ItemActivated` for it and runs its
      # callback. Callers add their own selection/render around this core. *item*
      # defaults to the row at *index*.
      #
      # Activation is not a selection change, so no `ItemSelected` is emitted here —
      # the `#current_index=` each caller runs around this emits it already.
      private def fire(index : Int32, item = @item_boxes[index]?)
        return unless item
        emit ::Crysterm::Event::ItemActivated, item, index
        @commands[index]?.try &.callback.try &.call
      end

      # Triggers a command: fires its action event + callback, selects it, and
      # re-renders.
      private def trigger(cmd : Command)
        el = cmd.widget
        return unless el
        idx = @item_boxes.index(el)
        fire (idx || current_index), el
        self.current_index = idx if idx
        request_render
      end

      # Generates the `{open}`/`{close}` tags used to colorize the command
      # prefix, based on `style.prefix.fg` (defaulting to light black).
      private def prefix_tags
        c = style.prefix.fg
        c = 0x7f7f7f if c.nil? || c < 0 # light black (default)
        hex = "#%06x" % (c & 0xffffff)
        {open: "{#{hex}-fg}", close: "{/#{hex}-fg}"}
      end

      def render(with_children = true)
        # Item boxes use a *content-relative* `left` (0 == the bar's content
        # origin): `Widget#aleft` already adds the parent's `ileft`, so starting
        # the cursor at `ileft` here would double-count the inset and shove items
        # off the edge whenever the bar had a border/padding.
        drawn = 0
        @item_boxes.each_with_index do |el, i|
          if i < @left_base
            el.hide
          else
            el.left = drawn
            drawn += (el.awidth || 0) + item_gap
            el.show
          end
        end
        super
      end

      # Whether the item box at *index* should render highlighted (`:selected`)
      # after a (re)selection targeting *offset*. The base bar highlights the
      # just-selected item; a bar with a different highlight model overrides this
      # and inherits the `#reapply_highlight` scaffold. (the current index is not
      # yet updated to *offset* when `#current_index=` calls this, so the target
      # index is passed explicitly.)
      protected def highlight_item?(item : Widget, index : Int32, offset : Int32) : Bool
        index == offset
      end

      # Re-imposes each item box's `:selected`/`:normal` state via
      # `#highlight_item?`. Also call it after a state change outside a selection
      # (a checkable toggling, a menu opening/closing, focus change).
      protected def reapply_highlight(offset : Int32 = current_index) : Nil
        @item_boxes.each_with_index do |item, i|
          item.state = highlight_item?(item, i, offset) ? :selected : :normal
        end
      end

      # Validated raw index for *child*: the `Int` itself when within
      # `0...count`, else `nil` — like `Mixin::ItemView#index_of`, through the
      # shared `Mixin::IndexValidation` body.
      def index_of(child : Int) : Int32?
        validated_index child, @commands.size
      end

      # Removes the command at *child* — a row index, the item/element widget, or
      # a widget embedded with `ToolBar#add_widget` — and returns its box (`nil`
      # when *child* resolves to no command). An out-of-range or negative row
      # index is a no-op.
      def remove_item(child : Int | Widget)
        i = child.is_a?(Int) ? index_of(child) : (@item_boxes.index(child) || index_of_embedded(child))
        return unless i && @item_boxes[i]?

        item = @item_boxes.delete_at i
        @ritems.delete_at i
        release_command @commands.delete_at i
        remove item

        # Auto prefixes are baked in at `#add_item` time as position numbers, but
        # number-key selection routes by raw index (`activate_item i`). A removal
        # shifts the indices, so renumber — otherwise removing `1:open` from
        # `1:open 2:save` leaves `2:save` while `2` now selects nothing.
        renumber_prefixes if auto_prefix?

        # Keep the selection cursor on the same logical command. `current_index` is
        # `left_base + left_offset` (an index), so removing an item *before* it
        # shifts every later command down by one, and the cursor must follow.
        if i < current_index
          # The formerly-selected command is now one index lower.
          self.current_index = current_index - 1
        elsif i == current_index
          # The selected command itself was removed: fall back to the prior
          # command, skipping separators so the highlight never settles on a
          # non-selectable one. Falls forward when everything before the gap is a
          # separator.
          if sel = nearest_selectable(i - 1)
            self.current_index = sel
          end
        end

        emit ::Crysterm::Event::ItemRemoved
        item
      end

      # `#>>` is an operator alias for `#remove_item`, mirroring `#<<`.
      alias_method :>>, :remove_item

      # Builds a command's displayed title from its (optionally prefixed) text,
      # and updates `cmd.width` to match.
      private def command_title(cmd : Command) : String
        if cmd.embedded?
          # The embedded widget paints itself; its host box only reserves the
          # strip cells (`cmd.width`, set by `#add_embedded_item` before the box
          # is built), so there is no title to render under it.
          ""
        elsif cmd.separator?
          cmd.width = str_width(cmd.text) + 2
          cmd.text
        else
          prefix = cmd.prefix
          tags = prefix_tags
          title = (prefix ? "#{tags[:open]}#{prefix}#{tags[:close]}:" : "") + cmd.text
          # Item boxes render with `parse_tags: true`, so measure the *rendered*
          # width with tags stripped — otherwise `{bold}File{/bold}` counts its
          # markup and oversizes the box. Must be `str_width`, not a raw
          # `.size`/`Unicode.display_width`: it dispatches display-column vs
          # codepoint counting on `full_unicode?`, matching how the box's own
          # content engine lays the text out.
          len = str_width clean_tags((prefix ? "#{prefix}:" : "") + cmd.text)
          cmd.width = len + 2
          title
        end
      end

      # Reassigns each auto-prefixed command the position number matching its raw
      # index, rebuilds its label + box width, and re-packs every item's `left` so
      # the row stays flush even when a label width changes (e.g. `10:` shrinking
      # to `9:`).
      private def renumber_prefixes : Nil
        @commands.each_with_index do |cmd, i|
          next unless cmd.auto_prefix?
          cmd.prefix = (i + 1).to_s
          cmd.widget.try &.set_content command_title(cmd)
        end
        drawn = 0
        @commands.each do |cmd|
          cmd.widget.try do |el|
            el.left = drawn
            el.width = cmd.width
          end
          drawn += cmd.width + item_gap
        end
      end

      # Installs *cmd*'s global-hotkey handler on the current window, if the bar
      # is attached and the command actually has keys + a callback. Idempotent:
      # `Subscription#on` cancels any prior handler first, so a re-install after
      # a detach/attach can't stack duplicates.
      private def install_command_hotkey(cmd : Command) : Nil
        return unless w = window?
        keys = cmd.keys
        return unless keys && cmd.callback
        sub = (cmd.key_handler ||= ::Crysterm::Subscription.new)
        sub.on(w, ::Crysterm::Event::KeyPress) do |e|
          # Don't act on a character another widget already consumed (a focused
          # editor typing the hotkey char).
          next if e.accepted?
          if keys.includes? e.char.to_s
            # Handled: accept *before* triggering (matching
            # `KeyShortcuts#on_key`) so the key stops propagating to other
            # window-level handlers and to `Application`'s default quit keys
            # ('q' is the doc'd example hotkey!) even if the callback tears
            # the surface down.
            e.accept
            trigger cmd
          end
        end
      end

      # (Re)installs every command's global-hotkey handler on the current window.
      private def install_command_hotkeys : Nil
        @commands.each { |cmd| install_command_hotkey cmd }
      end

      # Uninstalls every command's global-hotkey handler. The `Subscription`
      # captured its window at install time, so this works even after the bar
      # has detached (`window?` gone nil).
      private def uninstall_command_hotkeys : Nil
        @commands.each { |cmd| cmd.key_handler.try &.off }
      end

      # Removes a command's global-hotkey handler from the window, so it stops
      # firing once the command is gone.
      private def detach_command(cmd : Command)
        cmd.key_handler.try &.off
        cmd.key_handler = nil
      end

      # Releases a command being dropped from the bar: its hotkey handler, plus
      # any widget embedded with `ToolBar#add_widget`. The embedded widget is the
      # caller's, so it is detached free-standing rather than going down with the
      # discarded host item box, and can be re-parented or re-added afterwards.
      # (`#destroy` deliberately keeps the narrower `#detach_command`: a
      # destroyed bar takes its whole subtree with it.)
      private def release_command(cmd : Command)
        detach_command cmd
        cmd.embedded.try &.detach_from_tree
      end

      # Index of the command hosting *widget* as an embedded item, else `nil`.
      # Lets the widget handed back by `ToolBar#add_widget` be passed straight to
      # `#remove_item`, exactly like an item box.
      private def index_of_embedded(widget : Widget) : Int32?
        @commands.index { |cmd| cmd.embedded == widget }
      end

      # Tears down every command's global-hotkey handler so none linger on the
      # window after the bar is destroyed.
      def destroy
        @commands.each { |cmd| detach_command cmd }
        super
      end

      # The nearest selectable command index at or before *from*, else the
      # nearest one after it, or `nil` when the bar holds no selectable command
      # at all. "Selectable" is `Command#selectable?`: neither a separator nor an
      # embedded widget.
      private def nearest_selectable(from : Int32) : Int32?
        NavKeys.nearest_selectable(@commands.size, from, -1) { |i| !@commands[i].selectable? }
      end

      # Moves the selection by *delta* (negative = left), stepping over any
      # non-selectable command so the highlight never lands on one.
      def move_selection(delta : Int32)
        n = @commands.size
        return if n == 0

        dir = delta >= 0 ? 1 : -1
        idx = current_index
        delta.abs.times do
          ni = NavKeys.nearest_selectable(n, idx + dir, dir) { |i| !@commands[i].selectable? }
          break unless ni
          idx = ni
        end

        self.current_index = idx
      end

      # Moves the selection `offset` items to the left.
      def move_left(offset = 1)
        move_selection -offset
      end

      # Moves the selection `offset` items to the right.
      def move_right(offset = 1)
        move_selection offset
      end

      # Selects the item at `index` and emits `Event::CurrentChanged`. Selection
      # only — it does NOT run the command's callback, mirroring Qt, where
      # `setCurrentIndex` emits `currentChanged` while `activated` is a separate
      # signal (here, `#activate_item`).
      def select_item(index : Int)
        # An out-of-range (including negative) index is a no-op — `#index_of`
        # validates instead of letting `Array#[]?` resolve `-1` from the end.
        return unless i = index_of index
        cmd = @commands[i]
        # A separator (or an embedded widget, which owns its own focus) is not a
        # real item: selecting one would settle the highlight on a non-selectable
        # command. `auto_command_keys` routes here by raw index, so a number
        # landing on one must be a no-op too.
        return unless cmd.selectable?
        self.current_index = i
        request_render
        emit ::Crysterm::Event::CurrentChanged, i
      end

      # Selects the item at `index` *and* fires its command — what a number key
      # (`auto_command_keys`) means. Applies the same range/separator guards as
      # `#select_item`, so a rejected index runs no callback either. Routed
      # through `#fire`, the shared activation core, so a number-key activation
      # emits `Event::ItemActivated` exactly like Enter/click/hotkey do.
      def activate_item(index : Int)
        return unless i = index_of index
        return unless @commands[i].selectable?
        select_item i
        fire i
      end

      def handle_key_press(e)
        # Number-key selection (`auto_command_keys`): only while focused, so it
        # can't collide with numeric input elsewhere. '1'..'9' pick tabs 0..8,
        # '0' picks the 10th (index 9).
        if auto_command_keys? && (c = e.char) && ('0'..'9').includes?(c)
          i = c.to_i - 1
          i = 9 if i < 0
          activate_item i
          e.accept
          return
        end

        # Tab/Shift+Tab are deliberately NOT item-navigation keys (Qt's
        # `QTabBar` likewise leaves them alone): left unhandled here, they fall
        # through to the window's `tab_navigation`, so keyboard focus can leave
        # the bar instead of being trapped cycling its items.
        case
        when e.key == ::Tput::Key::Left, (@vi_keys && e.char == 'h')
          move_left
          request_render
        when e.key == ::Tput::Key::Right, (@vi_keys && e.char == 'l')
          move_right
          request_render
        when e.key == ::Tput::Key::Enter, (@vi_keys && e.char == 'k')
          fire current_index
          request_render
        when e.key == ::Tput::Key::Escape, (@vi_keys && e.char == 'q')
          if item = @item_boxes[current_index]?
            emit ::Crysterm::Event::ItemActivated, item, current_index
            emit ::Crysterm::Event::ItemCancelled, item, current_index
          end
          # A chrome bar (`region_focusable?`) leaves the real Escape
          # un-consumed so it bubbles to the window's region-navigation
          # fallback, which returns focus to the central area (the "leave
          # chrome" gesture — see `window_region_focus.cr`). Only Escape
          # itself: the vi cancel 'q' must still be consumed below, or it
          # reaches the default quit keys and exits the app.
          return if e.key == ::Tput::Key::Escape && region_focusable? && window?.try(&.region_navigation?)
        else
          return
        end

        # Consume every handled key so it doesn't also drive an ancestor
        # (mirrors `Mixin::ItemView#handle_key_press`): an un-accepted key would go
        # on to window-level accelerators (a dialog's Enter/Escape) and to
        # `Application`'s default quit keys — where the bar's own vi cancel key
        # 'q' would quit the whole app.
        e.accept
      end
    end
  end
end
