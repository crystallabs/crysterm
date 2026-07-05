module Crysterm
  module Mixin
    # The "horizontal bar of selectable commands" concern, extracted from
    # `Widget::ListBar` so the command model can be shared without inheritance.
    #
    # Qt makes `QMenuBar` and `QToolBar` siblings under `QWidget`, not under a
    # shared "bar" class. Crysterm mirrors that: `MenuBar`/`ToolBar` derive `Box`
    # directly and `include` this module for the command model, left-to-right
    # layout, keyboard navigation, hotkeys, and rendering. `Widget::ListBar`
    # stays a usable concrete widget that also includes it (a peer of
    # `MenuBar`/`ToolBar`, like `Input` including `Mixin::Interactive`).
    #
    # Call `setup_action_bar` from `initialize` (after `super`) to wire the
    # keyboard/focus handlers.
    module ActionBar
      # A single command/tab shown in an action bar.
      class Command
        # Text shown after the (optional) prefix.
        property text : String

        # Prefix shown before `text` (e.g. the auto-generated `1`, `2`, ...).
        # `nil` means no prefix is rendered.
        property prefix : String?

        # Whether `#prefix` was auto-generated (the `N:` position number) rather
        # than set explicitly or derived from a hotkey. Only auto prefixes are
        # renumbered when a sibling is removed (see `#remove_item`), so the shown
        # `N:` labels stay in step with the raw index number-key selection uses.
        property? auto_prefix = false

        # Invoked when the command is triggered (Enter / click / hotkey).
        property callback : Proc(Nil)?

        # Per-command global hotkeys (matched against the pressed character).
        # When set, the first entry also becomes the displayed `prefix`.
        property keys : Array(String)?

        # The `Box` rendering this command, assigned by `#add`.
        property element : Widget::Box?

        # Computed display width of this command's box.
        property width : Int32 = 0

        # Whether this is a non-selectable visual separator rather than a real
        # command (Qt's `QToolBar#addSeparator`).
        property? separator = false

        # Window-level subscription for this command's global hotkeys (`#keys`).
        # A `Subscription` captures the *window it was installed on* at subscribe
        # time, so `#off` removes it from that exact window regardless of the
        # bar's later `window?` — no leak after a reparent/detach.
        property key_handler : ::Crysterm::Subscription?

        def initialize(@text, @callback = nil, *, @prefix = nil, @keys = nil)
        end
      end

      # The element boxes, one per command (parallel to `#commands`/`#ritems`).
      # `@items` itself is declared on `Widget`.

      # Tag-stripped command texts, parallel to `#items`.
      property ritems = [] of String

      # The commands, parallel to `#items`.
      property commands = [] of Command

      # Index of the left-most fully-visible item (for horizontal scrolling).
      property left_base = 0

      # Offset of the selected item relative to `#left_base`.
      property left_offset = 0

      # React to mouse clicks on items?
      property? mouse = false

      # Select commands with the number keys `1`..`9`/`0`?
      property? auto_command_keys = false

      # Prefix each command with an auto-generated `N:` label (the Blessed
      # default). Turn off for a plain bar of labels, e.g. a `Widget::MenuBar`.
      property? auto_prefix = true

      # Inert cells between adjacent item boxes (no leading gap, so inert cells
      # fall only after the last item). Defaults to 2; a
      # `Widget::MenuBar`/`Widget::ToolBar` sets it to 0 so titles/buttons pack
      # flush — each item box already carries its own side padding
      # (`width = text + 2`), so 0 still leaves breathing room.
      property item_gap : Int32 = 2

      # Wires the keyboard navigation and focus re-selection handlers, and sets
      # the bar's interaction defaults. Call from `initialize` after `super`.
      # `mouse`/`auto_prefix` default to the widget's existing values, so a plain
      # `ListBar` calls it bare, while `MenuBar`/`ToolBar` pass
      # `mouse: true, auto_prefix: false`.
      private def setup_action_bar(mouse = @mouse, auto_prefix = @auto_prefix) : Nil
        @mouse = mouse
        @auto_prefix = auto_prefix

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        # `auto_command_keys` (number-key selection) is handled in the
        # widget-local `#on_keypress` rather than a global `window.on`: number
        # keys must not be hijacked while unfocused (would collide with numeric
        # input elsewhere), and a widget-local handler is torn down with the
        # widget instead of leaking on the window.

        on(::Crysterm::Event::Focus) { selekt selected }

        # Command hotkeys are window-level accelerators, so they must be tied to
        # the window lifecycle (mirroring `MenuBar`'s menu-shortcut handling):
        # (re)install on attach, uninstall on detach. Without this, a bar that
        # merely `remove`s (toolbar swap) leaves its hotkeys firing on a window
        # it's no longer on, and one added while detached would never install.
        on(::Crysterm::Event::Attach) { install_command_hotkeys }
        on(::Crysterm::Event::Detach) { uninstall_command_hotkeys }
      end

      # Currently-selected absolute index.
      def selected
        @left_base + @left_offset
      end

      # (Re)defines the full set of commands from an array of `Command`s,
      # plain strings, or `name => callback` pairs.
      def set_items(commands : Array(Command))
        @items.each &.remove_from_parent
        @commands.each { |cmd| detach_command cmd }
        @items.clear
        @ritems.clear
        @commands.clear

        commands.each { |cmd| add cmd }

        emit ::Crysterm::Event::SetItems
      end

      # :ditto:
      def set_items(commands : Array(String))
        set_items commands.map { |text| Command.new text }
      end

      # :ditto:
      def set_items(commands : Hash(String, Proc(Nil)))
        list = [] of Command
        commands.each do |name, cb|
          list << Command.new name, cb
        end
        set_items list
      end

      # Appends a command given as plain text plus optional callback/hotkeys.
      def add(text : String, callback : Proc(Nil)? = nil, *, keys : Array(String)? = nil)
        add Command.new text, callback, keys: keys
      end

      # :ditto:
      def add(text : String, *, keys : Array(String)? = nil, &callback : -> Nil)
        add Command.new text, callback, keys: keys
      end

      # Appends a non-selectable separator (Qt's `QToolBar#addSeparator`).
      def add_separator(char : String = "│")
        cmd = Command.new char
        cmd.separator = true
        add cmd
      end

      # Appends a `Command`.
      def add(cmd : Command)
        # Pack each item flush after the ones already added: its left is the sum
        # of their widths plus `item_gap` between each, no leading gap. Built
        # from stored command widths (relative to the bar), so it's correct
        # before the bar is parented/rendered — unlike reading the previous
        # item's absolute `aleft`, which double-counted the bar's own offset.
        drawn = @commands.sum(&.width) + item_gap * @commands.size

        unless cmd.separator?
          if auto_prefix? && cmd.prefix.nil?
            cmd.prefix = (@items.size + 1).to_s
            cmd.auto_prefix = true
          end

          # A per-command hotkey doubles as the displayed prefix, matching Blessed
          # (and is not an auto prefix — it must not be renumbered).
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

        # Each item box renders per its own state: the selected item uses the
        # bar's `selected` style, others the `item` style. `dup` both: `Style#item`
        # falls back to `self`, so every item would otherwise share one `Style`
        # instance — and `Widget#hide`/`#show` mutate `state_style.visible` in
        # place, so the render scroll loop's hide/show would toggle a single shared
        # flag and never actually hide scrolled-off items.
        item.styles.normal = style.item.dup
        item.styles.selected = styles.selected.dup

        cmd.element = item
        @ritems.push clean_tags cmd.text
        @items.push item
        @commands.push cmd
        append item

        # Per-command hotkeys are global accelerators (fire regardless of focus,
        # like a toolbar shortcut). Installed only when the bar is attached; the
        # `Event::Attach` handler re-covers commands added while detached.
        install_command_hotkey cmd

        if @mouse && !cmd.separator?
          item.on(::Crysterm::Event::Click) do
            trigger cmd
          end
        end

        # Auto-select the first *selectable* command. Testing `@items.size == 1`
        # would fire only for the very first item added, so a bar opening with a
        # leading `add_separator` would never select its first real command —
        # `selected` would stick on the non-selectable separator with a dead
        # Enter. Fire on the first non-separator command instead. `@left_base`/
        # `@left_offset` (selected == their sum) are set directly rather than via
        # `#selekt`, since its window math is gated on a laid-out `@lpos` and
        # can't move the index before the first render. `@left_base` stays 0 so
        # every command, separators included, remains visible.
        if !cmd.separator? && @commands.count { |c| !c.separator? } == 1
          @left_base = 0
          @left_offset = @items.size - 1
          selekt selected
        end

        emit ::Crysterm::Event::AddItem

        item
      end

      # Fires the command at *index*: emits `ActionItem`/`SelectItem` for it and
      # runs its callback. Shared by keyboard-Enter activation and `#trigger`
      # (each adds its own selection/render around this core). *item* defaults to
      # the row at *index*; `#trigger` passes the command's element explicitly.
      private def fire(index : Int32, item = @items[index]?)
        return unless item
        emit ::Crysterm::Event::ActionItem, item, index
        emit ::Crysterm::Event::SelectItem, item, index
        @commands[index]?.try &.callback.try &.call
      end

      # Triggers a command: fires its action/select events + callback, selects
      # it, and re-renders.
      private def trigger(cmd : Command)
        el = cmd.element
        return unless el
        idx = @items.index(el) || selected
        fire idx, el
        selekt el
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
        # the cursor at `ileft` here would double-count the inset and shove
        # items right (off the edge) whenever the bar had a border/padding.
        # Start at 0, matching `#add` and `#selekt`'s visibility math.
        drawn = 0
        @items.each_with_index do |el, i|
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

      # Selects the item at `offset` (an index or an item/element widget),
      # adjusting the horizontal scroll window so it is visible.
      def selekt(offset : Int)
        if offset < 0
          offset = 0
        elsif offset >= @items.size
          offset = @items.size - 1
        end

        el = @items[offset]?

        # Keep every item box's state in sync with the new selection so it
        # renders with `styles.selected`. Routed through `#highlight_item?` so a
        # bar with its own highlight semantics (ToolBar: checked checkables;
        # MenuBar: the open menu) inherits the re-highlight without re-overriding
        # `#selekt`.
        reapply_highlight offset

        # Mirror Blessed's `lpos = this._getCoords(); if (!lpos) return;`: the
        # horizontal-scroll math below needs a real layout. A top-level widget
        # appended to a `Window` has no `#parent`, so gating on `#parent`
        # wrongly skips the scroll update for every
        # window-level listbar, freezing `#selected` at 0. Gate on `@lpos`
        # instead (set after the first render; the public
        # `#last_rendered_position` raises when unrendered, so it can't be used
        # as a predicate here).
        unless @lpos
          # Before the first render there's no layout for the horizontal-scroll
          # math, but `selected` (== `@left_base + @left_offset`) must still move
          # to *offset* — otherwise the highlight/`SelectItem` point at *offset*
          # while Enter (`fire selected`) fires the old command. Record the index
          # (exactly what `#add`'s auto-select does) before emitting.
          el.try do |e|
            @left_base = 0
            @left_offset = offset
            emit ::Crysterm::Event::SelectItem, e, offset
          end
          return
        end

        return unless el

        width = (awidth || 0) - iwidth
        drawn = 0
        visible = 0
        @items.each_with_index do |item, i|
          next if i < @left_base
          w = item.awidth || 0
          next if w <= 0
          drawn += w + item_gap
          visible += 1 if drawn <= width
        end

        diff = offset - (@left_base + @left_offset)
        if offset > @left_base + @left_offset
          if offset > @left_base + visible - 1
            @left_offset = 0
            @left_base = offset
          else
            @left_offset += diff
          end
        elsif offset < @left_base + @left_offset
          diff = -diff
          if offset < @left_base
            @left_offset = 0
            @left_base = offset
          else
            @left_offset -= diff
          end
        end

        emit ::Crysterm::Event::SelectItem, el, offset
      end

      # :ditto:
      def selekt(widget : Widget)
        if i = @items.index widget
          selekt i
        end
      end

      # Whether the item box at *index* should render highlighted (`:selected`)
      # after a (re)selection targeting *offset*. The base bar highlights the
      # just-selected item; subclasses with a different highlight model override
      # this and inherit the `#reapply_highlight` scaffold. (`selected` is not
      # yet updated to *offset* when `#selekt` calls this, so the target index is
      # passed explicitly.)
      protected def highlight_item?(item : Widget, index : Int32, offset : Int32) : Bool
        index == offset
      end

      # Re-imposes each item box's `:selected`/`:normal` state via
      # `#highlight_item?`. Shared by `#selekt` and by subclasses that must
      # re-light after a state change outside a selection (a checkable toggling,
      # a menu opening/closing, focus change) — so the walk lives once.
      protected def reapply_highlight(offset : Int32 = selected) : Nil
        @items.each_with_index do |item, i|
          item.state = highlight_item?(item, i, offset) ? :selected : :normal
        end
      end

      # Removes the command at the given index or item/element widget.
      def remove_item(child : Int | Widget)
        i = child.is_a?(Int) ? child : @items.index(child)
        return unless i && @items[i]?

        item = @items.delete_at i
        @ritems.delete_at i
        detach_command @commands.delete_at i
        remove item

        # Auto prefixes were baked in at `#add` time as position numbers, but
        # number-key selection routes by raw index (`select_tab i`). After a
        # removal the indices shifted, so renumber the auto-prefixed commands and
        # rebuild their labels/positions — otherwise e.g. removing `1:open` from
        # `1:open 2:save` would leave `2:save` while `2` now selects nothing.
        renumber_prefixes if auto_prefix?

        # Keep the selection cursor on the same logical command. `selected` is
        # `left_base + left_offset` (an index), so removing an item *before* it
        # shifts every later command down by one, and the cursor must follow.
        # Mirrors `ItemView#remove_item`'s cursor realignment.
        if i < selected
          # The formerly-selected command is now one index lower.
          selekt selected - 1
        elsif i == selected
          # The selected command itself was removed: fall back to the prior
          # command, skipping separators so the highlight never settles on a
          # non-selectable one (mirrors `#move`'s separator-stepping and `#add`'s
          # leading-separator skip). Falls forward when everything before the
          # gap is a separator.
          if sel = nearest_selectable(i - 1)
            selekt sel
          end
        end

        emit ::Crysterm::Event::RemoveItem
        item
      end

      # Builds a command's displayed title from its (optionally prefixed) text,
      # and updates `cmd.width` to match. Shared by `#add` and
      # `#renumber_prefixes` so both stay in sync.
      private def command_title(cmd : Command) : String
        if cmd.separator?
          cmd.width = cmd.text.size + 2
          cmd.text
        else
          prefix = cmd.prefix
          tags = prefix_tags
          title = (prefix ? "#{tags[:open]}#{prefix}#{tags[:close]}:" : "") + cmd.text
          # Item boxes render with `parse_tags: true`, so measure the *rendered*
          # width with tags stripped — otherwise `{bold}File{/bold}` counts its
          # markup and oversizes the box, leaving a dead gap after the item.
          len = clean_tags((prefix ? "#{prefix}:" : "") + cmd.text).size
          cmd.width = len + 2
          title
        end
      end

      # Reassigns each auto-prefixed command the position number matching its raw
      # index, rebuilds its label + box width, and re-packs every item's `left`
      # (mirroring `#add`'s packing) so the row stays flush even when a label
      # width changes (e.g. `10:` shrinking to `9:`).
      private def renumber_prefixes : Nil
        @commands.each_with_index do |cmd, i|
          next unless cmd.auto_prefix?
          cmd.prefix = (i + 1).to_s
          cmd.element.try &.set_content command_title(cmd)
        end
        drawn = 0
        @commands.each do |cmd|
          cmd.element.try do |el|
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
          # editor typing the hotkey char) — mirrors `Action#install_shortcut`.
          next if e.accepted?
          if keys.includes? e.char.to_s
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

      # Tears down every command's global-hotkey handler so none linger on the
      # window after the bar is destroyed.
      def destroy
        @commands.each { |cmd| detach_command cmd }
        super
      end

      # The nearest selectable (non-separator) command index at or before
      # *from*, else the nearest one after it, or `nil` when the bar holds no
      # selectable command at all. Used to keep the selection cursor off
      # separators after a removal (see `#remove_item`).
      private def nearest_selectable(from : Int32) : Int32?
        n = @commands.size
        return nil if n == 0
        i = from.clamp(0, n - 1)
        j = i
        while j >= 0
          return j unless @commands[j].separator?
          j -= 1
        end
        j = i + 1
        while j < n
          return j unless @commands[j].separator?
          j += 1
        end
        nil
      end

      # Moves the selection by `offset` (negative = left), stepping over any
      # separator commands so the highlight never lands on one.
      def move(offset)
        n = @commands.size
        return if n == 0

        dir = offset >= 0 ? 1 : -1
        idx = selected
        offset.abs.times do
          ni = idx + dir
          while ni >= 0 && ni < n && (@commands[ni]?.try &.separator?)
            ni += dir
          end
          break if ni < 0 || ni >= n
          idx = ni
        end

        selekt idx
      end

      # Moves the selection `offset` items to the left.
      def move_left(offset = 1)
        move -offset
      end

      # Moves the selection `offset` items to the right.
      def move_right(offset = 1)
        move offset
      end

      # Selects (and triggers the callback of) the tab at `index`.
      def select_tab(index : Int)
        # An out-of-range index is a no-op (must not emit a `SelectTab`
        # carrying a nil item).
        cmd = @commands[index]?
        return if cmd.nil?
        # A separator is not a real tab: selecting one would settle the highlight
        # on a non-selectable command, the same state `#add`/`#remove_item`/
        # `#move` already avoid. `auto_command_keys` routes here by raw index, so
        # a number landing on a separator must be a no-op too.
        return if cmd.separator?
        cmd.callback.try &.call
        selekt index
        request_render
        emit ::Crysterm::Event::SelectTab, @items[index]?, index
      end

      def on_keypress(e)
        # Number-key selection (`auto_command_keys`): only while focused, so it
        # can't collide with numeric input elsewhere. '1'..'9' pick tabs 0..8,
        # '0' picks the 10th (index 9).
        if auto_command_keys? && (c = e.char) && ('0'..'9').includes?(c)
          i = c.to_i - 1
          i = 9 if i < 0
          select_tab i
          e.accept
          return
        end

        case
        when e.key == ::Tput::Key::Left, (@vi && e.char == 'h'),
             (e.key == ::Tput::Key::ShiftTab)
          move_left
          request_render
          e.accept if e.key == ::Tput::Key::ShiftTab
        when e.key == ::Tput::Key::Right, (@vi && e.char == 'l'),
             (e.key == ::Tput::Key::Tab)
          move_right
          request_render
          e.accept if e.key == ::Tput::Key::Tab
        when e.key == ::Tput::Key::Enter, (@vi && e.char == 'k')
          fire selected
          request_render
        when e.key == ::Tput::Key::Escape, (@vi && e.char == 'q')
          if item = @items[selected]?
            emit ::Crysterm::Event::ActionItem, item, selected
            emit ::Crysterm::Event::CancelItem, item, selected
          end
        end
      end
    end
  end
end
