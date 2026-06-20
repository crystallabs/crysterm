module Crysterm
  class Widget
    # Horizontal bar of selectable commands/tabs, a.k.a. a "listbar".
    #
    # Port of Blessed's `listbar` element. Each command is rendered as a small
    # `Box` laid out left-to-right; one is "selected" at a time. Commands can be
    # navigated with the arrow keys (or vi `h`/`l`), triggered with Enter, the
    # mouse, per-command hotkeys (`Command#keys`), or — when
    # `auto_command_keys` is on — the number keys `1`..`9`/`0`.
    #
    # ```
    # bar = Widget::ListBar.new keys: true, mouse: true, auto_command_keys: true
    # bar.add "open", -> { open_file }
    # bar.add "quit", -> { exit }, keys: ["q"]
    # ```
    class ListBar < Box
      # A single command/tab shown in a `ListBar`.
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

        # The `Box` rendering this command, assigned by `ListBar#add`.
        property element : Widget::Box?

        # Computed display width of this command's box.
        property width : Int32 = 0

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

      def initialize(
        commands = nil,
        *,
        @mouse = false,
        @auto_command_keys = false,
        **widget,
      )
        super **widget

        commands.try { |c| set_items c }

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        if @auto_command_keys
          screen.on(::Crysterm::Event::KeyPress) do |e|
            if ('0'..'9').includes? e.char
              i = e.char.to_i - 1
              i = 9 if i < 0
              select_tab i
            end
          end
        end

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

      # Appends a `Command`.
      def add(cmd : Command)
        prev = @items.last?

        drawn = if @parent.nil?
                  0
                else
                  prev ? (prev.aleft || 0) + (prev.awidth || 0) : 0
                end

        cmd.prefix ||= (@items.size + 1).to_s

        # A per-command hotkey doubles as the displayed prefix, matching Blessed.
        cmd.keys.try do |keys|
          cmd.prefix = keys[0] if keys[0]?
        end

        prefix = cmd.prefix
        tags = prefix_tags
        title = (prefix ? "#{tags[:open]}#{prefix}#{tags[:close]}:" : "") + cmd.text
        len = ((prefix ? "#{prefix}:" : "") + cmd.text).size
        cmd.width = len + 2

        item = Widget::Box.new(
          screen: screen,
          top: 0,
          left: drawn + 1,
          height: 1,
          width: cmd.width,
          content: title,
          align: ::Tput::AlignFlag::Center,
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

        # Per-command global hotkeys fire regardless of focus.
        cmd.keys.try do |keys|
          if cmd.callback
            screen.on(::Crysterm::Event::KeyPress) do |e|
              if keys.includes? e.char.to_s
                trigger cmd
              end
            end
          end
        end

        if @mouse
          item.on(::Crysterm::Event::Click) do
            trigger cmd
          end
        end

        selekt 0 if @items.size == 1

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
        screen.render
      end

      # Generates the `{open}`/`{close}` tags used to colorize the command
      # prefix, based on `style.prefix.fg` (defaulting to light black).
      private def prefix_tags
        fg = style.prefix.fg || "lightblack"
        fg = fg.sub(/^light(?!-)/, "light-").sub(/^bright(?!-)/, "bright-")
        {open: "{#{fg}-fg}", close: "{/#{fg}-fg}"}
      end

      def render(with_children = true)
        drawn = ileft
        @items.each_with_index do |el, i|
          if i < @left_base
            el.hide
          else
            el.left = drawn + 1
            drawn += (el.awidth || 0) + 2
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
          item.state = (i == offset) ? WidgetState::Selected : WidgetState::Normal
        end

        # Mirror Blessed's `lpos = this._getCoords(); if (!lpos) return;`: the
        # horizontal-scroll math below needs a real layout. A top-level widget
        # appended to a `Screen` has no `#parent` (a `Screen` is not a
        # `Widget`), so gating on `#parent` — as the original port did — wrongly
        # skipped the scroll update for every screen-level listbar, freezing
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
          drawn += w + 2
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
        @commands.delete_at i
        remove item

        selekt i - 1 if i == selected

        emit ::Crysterm::Event::RemoveItem
        item
      end

      # Moves the selection by `offset` (negative = left).
      def move(offset)
        selekt selected + offset
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
        if cmd = @commands[index]?
          cmd.callback.try &.call
          selekt index
          screen.render
        end
        emit ::Crysterm::Event::SelectTab, @items[index]?, index
      end

      def on_keypress(e)
        case
        when e.key == ::Tput::Key::Left, (@vi && e.char == 'h'),
             (e.key == ::Tput::Key::ShiftTab)
          move_left
          screen.render
          e.accept if e.key == ::Tput::Key::ShiftTab
        when e.key == ::Tput::Key::Right, (@vi && e.char == 'l'),
             (e.key == ::Tput::Key::Tab)
          move_right
          screen.render
          e.accept if e.key == ::Tput::Key::Tab
        when e.key == ::Tput::Key::Enter, (@vi && e.char == 'k')
          idx = selected
          if item = @items[idx]?
            emit ::Crysterm::Event::ActionItem, item, idx
            emit ::Crysterm::Event::SelectItem, item, idx
            @commands[idx]?.try &.callback.try &.call
          end
          screen.render
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
