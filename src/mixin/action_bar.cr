module Crysterm
  module Mixin
    # The "horizontal bar of selectable commands" concern, extracted from
    # `Widget::ListBar` so the command model can be shared without inheritance.
    #
    # Qt makes `QMenuBar` and `QToolBar` siblings under `QWidget`, not under any
    # shared "bar" class. Crysterm mirrors that: `MenuBar`/`ToolBar` derive `Box`
    # directly and `include` this module to get the command model, the
    # left-to-right item layout, keyboard navigation, hotkeys, and rendering. The
    # original `Widget::ListBar` stays a usable concrete widget that also includes
    # it (a peer of `MenuBar`/`ToolBar`, exactly as `Input` includes
    # `Mixin::Interactive`).
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

        # Window-level handler installed for this command's global hotkeys
        # (`#keys`). Retained so it can be removed when the command — or the whole
        # bar — is torn down, instead of leaking onto the window forever.
        property key_handler : ::Crysterm::Event::KeyPress::Wrapper?

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
      # fall only after the last item). Defaults to 2 — the historical spacing; a
      # `Widget::MenuBar`/`Widget::ToolBar` sets it to 0 so its titles/buttons
      # pack flush, with every cell up to the last one belonging to an item. Each
      # item box already carries its own side padding (`width = text + 2`), so 0
      # still leaves breathing between items.
      property item_gap : Int32 = 2

      # Wires the keyboard navigation and focus re-selection handlers, and sets
      # the bar's interaction defaults. Call from `initialize` after `super`.
      # `mouse`/`auto_prefix` default to the values already on the widget, so a
      # plain `ListBar` calls it bare, while `MenuBar`/`ToolBar` (mouse-driven,
      # label-only) pass `mouse: true, auto_prefix: false` in one line.
      private def setup_action_bar(mouse = @mouse, auto_prefix = @auto_prefix) : Nil
        @mouse = mouse
        @auto_prefix = auto_prefix

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        # `auto_command_keys` (number-key selection) is handled inside the
        # widget-local `#on_keypress` rather than via a global `window.on`: number
        # keys must not be hijacked while the bar is unfocused (they would collide
        # with any numeric input elsewhere), and a widget-local handler is torn
        # down with the widget instead of leaking/accumulating on the window.

        on(::Crysterm::Event::Focus) { selekt selected }
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
        # of their widths plus `item_gap` inert cells between each. No leading
        # gap, so inert cells fall only after the last item. Built from the stored
        # command widths (relative to the bar), so it's correct before the bar is
        # parented/rendered — unlike reading the previous item's absolute `aleft`,
        # which double-counted the bar's own offset.
        drawn = @commands.sum(&.width) + item_gap * @commands.size

        if cmd.separator?
          # Separators carry no prefix/hotkey and are sized to their glyph.
          title = cmd.text
          cmd.width = cmd.text.size + 2
        else
          cmd.prefix ||= (@items.size + 1).to_s if auto_prefix?

          # A per-command hotkey doubles as the displayed prefix, matching Blessed.
          cmd.keys.try do |keys|
            cmd.prefix = keys[0] if keys[0]?
          end

          prefix = cmd.prefix
          tags = prefix_tags
          title = (prefix ? "#{tags[:open]}#{prefix}#{tags[:close]}:" : "") + cmd.text
          len = ((prefix ? "#{prefix}:" : "") + cmd.text).size
          cmd.width = len + 2
        end

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

        # Each item box renders according to its own state: the selected item
        # uses the bar's `selected` style, all others the bar's `item` style.
        item.styles.normal = style.item
        item.styles.selected = styles.selected

        cmd.element = item
        @ritems.push clean_tags cmd.text
        @items.push item
        @commands.push cmd
        append item

        # Per-command hotkeys are intentional global accelerators (they fire
        # regardless of focus, like a toolbar shortcut). The handler wrapper is
        # stored on the command so it can be removed again (see `#detach_command`).
        cmd.keys.try do |keys|
          if cmd.callback
            cmd.key_handler = window.on(::Crysterm::Event::KeyPress) do |e|
              if keys.includes? e.char.to_s
                trigger cmd
              end
            end
          end
        end

        if @mouse && !cmd.separator?
          item.on(::Crysterm::Event::Click) do
            trigger cmd
          end
        end

        # Auto-select the first *selectable* command. The old `@items.size == 1`
        # test fired only for the very first item added, so a bar that opened
        # with one or more separators (a leading `add_separator`) never selected
        # its first real command — `selected` (and the focus highlight) stayed
        # stuck on the non-selectable separator, with a dead Enter, until the
        # user arrowed off it. Fire when this is the first non-separator command
        # instead. The selection lives in `@left_base`/`@left_offset` (selected ==
        # their sum): set them directly, since `#selekt`'s window math is gated on
        # a laid-out `@lpos` and so cannot move the index before the first render
        # (the original worked only because index 0 needs no offset). `@left_base`
        # stays 0 so every command — separators included — remains visible.
        if !cmd.separator? && @commands.count { |c| !c.separator? } == 1
          @left_base = 0
          @left_offset = @items.size - 1
          selekt selected
        end

        emit ::Crysterm::Event::AddItem

        item
      end

      # Triggers a command: emits action/select events, runs its callback,
      # selects it, and re-renders.
      private def trigger(cmd : Command)
        el = cmd.element
        return unless el
        idx = @items.index(el) || selected
        emit ::Crysterm::Event::ActionItem, el, idx
        emit ::Crysterm::Event::SelectItem, el, idx
        cmd.callback.try &.call
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
        # Item boxes are positioned with a *content-relative* `left` (0 == the
        # bar's content origin): `Widget#aleft` already adds the parent's `ileft`
        # to a child's relative `left`, so starting the cursor at `ileft` here
        # double-counted the inset and shoved every item right by `ileft` (and
        # the last items off the right edge) whenever the bar had a border or
        # left padding. Start at 0, matching item creation in `#add` and the
        # `drawn = 0` content-relative origin in `#selekt`'s visibility math.
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

        # Keep every item box's state in sync with the new selection so the
        # selected one renders with `styles.selected`.
        @items.each_with_index do |item, i|
          item.state = (i == offset) ? :selected : :normal
        end

        # Mirror Blessed's `lpos = this._getCoords(); if (!lpos) return;`: the
        # horizontal-scroll math below needs a real layout. A top-level widget
        # appended to a `Window` has no `#parent` (a `Window` is not a
        # `Widget`), so gating on `#parent` — as the original port did — wrongly
        # skipped the scroll update for every window-level listbar, freezing
        # `#selected` (= `left_base + left_offset`) at 0. Gate on having been
        # laid out instead (`@lpos` is set after the first render, for both
        # parented and top-level bars; nil beforehand — note that the public
        # `#last_rendered_position` *raises* when unrendered, so it can't be
        # used as a predicate here).
        unless @lpos
          el.try { |e| emit ::Crysterm::Event::SelectItem, e, offset }
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

      # Removes the command at the given index or item/element widget.
      def remove_item(child : Int | Widget)
        i = child.is_a?(Int) ? child : @items.index(child)
        return unless i && @items[i]?

        item = @items.delete_at i
        @ritems.delete_at i
        detach_command @commands.delete_at i
        remove item

        # Keep the selection cursor on the same logical command. `selected` is
        # `left_base + left_offset` (an *index*), so removing an item *before* it
        # shifts every later command — including the selected one — down by one,
        # and the cursor must slide down with them. Without this the cursor stayed
        # at its old numeric index and silently pointed at the next command (or,
        # when the last command was selected, past the end at nothing). This
        # mirrors `ItemView#remove_item`'s cursor realignment.
        if i < selected
          # The formerly-selected (selectable) command is now one index lower.
          selekt selected - 1
        elsif i == selected
          # The selected command itself was removed: fall back to the prior
          # command, but skip back over any separators so the highlight never
          # settles on a non-selectable separator (a dead cursor whose Enter does
          # nothing) — mirroring how `#move` steps over separators, and the
          # leading-separator skip in `#add`'s auto-select. Falls forward to the
          # next selectable command when everything before the gap is a separator.
          if sel = nearest_selectable(i - 1)
            selekt sel
          end
        end

        emit ::Crysterm::Event::RemoveItem
        item
      end

      # Removes a command's global-hotkey handler from the window (if any), so it
      # stops firing once the command is gone.
      private def detach_command(cmd : Command)
        cmd.key_handler.try { |w| window?.try &.off ::Crysterm::Event::KeyPress, w }
        cmd.key_handler = nil
      end

      # Tears down every command's global-hotkey handler before the bar is
      # destroyed, so none linger on the window.
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
        # An out-of-range index is a no-op (previously it still emitted a
        # `SelectTab` carrying a nil item).
        cmd = @commands[index]?
        return if cmd.nil?
        # A separator is not a real tab: selecting one would settle the highlight
        # on a non-selectable command — a dead cursor whose Enter does nothing,
        # the very state `#add`'s leading-separator skip, `#remove_item`'s
        # `nearest_selectable` realignment and `#move`'s separator-stepping all
        # already avoid. The `auto_command_keys` number keys route here by raw
        # index (`select_tab i`), so a number landing on a separator must not
        # highlight it (nor fire its nil callback / emit a `SelectTab` for it).
        # Treat it like the out-of-range case above: a no-op.
        return if cmd.separator?
        cmd.callback.try &.call
        selekt index
        request_render
        emit ::Crysterm::Event::SelectTab, @items[index]?, index
      end

      def on_keypress(e)
        # Number-key selection (`auto_command_keys`): only while focused, so it
        # can't collide with numeric input elsewhere. '1'..'9' pick tabs 0..8 and
        # '0' picks the 10th (index 9), matching the original behavior.
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
          idx = selected
          if item = @items[idx]?
            emit ::Crysterm::Event::ActionItem, item, idx
            emit ::Crysterm::Event::SelectItem, item, idx
            @commands[idx]?.try &.callback.try &.call
          end
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
