module Crysterm
  class Widget
    class List < Widget
      property ignore_keys = true
      property scrollable = true

      property _list_initialized = false

      # property items = [] of Widget::Box # Already defined in widget.cr

      property ritems = [] of String
      property selected = 0

      # Tag-stripped text of the currently selected item (`""` when the list is
      # empty). Kept in sync by `#selekt`; useful e.g. for `Widget::Form`
      # value collection.
      getter value : String = ""

      # Lazily-built map of `clean_tags(item) => first index`, used by the
      # `get_item_index(String)` fallback so it doesn't re-run `clean_tags`
      # (a full gsub per item) on every lookup. Invalidated to `nil` whenever
      # `@ritems` is mutated; see `invalidate_item_index`.
      @clean_tags_index : Hash(String, Int32)? = nil

      @_is_list = true
      @interactive = true

      # @mouse = false # XXX

      # XXX Setting items directly doesn't work so far. Add them later.
      # def initialize(items = nil, input = true, **box)
      def initialize(input = true, **box)
        super **box, input: input, keys: true

        @value = ""

        # items.try do |items2|
        #  @ritems = items2
        #  items2.each do |item3|
        #    append_item item3
        #  end
        # end

        selekt 0

        # TODO
        # if @mouse
        # end

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        on ::Crysterm::Event::Resize, ->on_resize(::Crysterm::Event::Resize)
        on ::Crysterm::Event::Adopt, ->on_adopt(::Crysterm::Event::Adopt)
        on ::Crysterm::Event::Remove, ->on_remove(::Crysterm::Event::Remove)
      end

      # Returns the `Style` an item box should render with, given whether it is
      # the selected item.
      #
      # The list draws its *own* border (and background) around the whole
      # widget, so an individual item must never carry a border of its own.
      # The non-selected branch of `Style#item` falls back to the list's own
      # style (`@item || self`), which — when the list has a border — would make
      # every non-selected item draw a nested border, showing up as stray
      # line-drawing characters. We therefore strip the border from the item
      # style here. The selected branch (`styles.selected`) is already a
      # separate, border-less style, but is run through the same guard for
      # symmetry (and in case a user gives the selected style a border). See
      # `Widget#_render`, which calls this.
      def item_render_style(selected : Bool) : Style
        base = selected ? styles.selected : style.item
        return base unless base.border.any?

        borderless = base.dup
        borderless.border = false
        borderless
      end

      def create_item(content, screen = ::Crysterm::Screen.global, align : ::Tput::AlignFlag | Shorthands = ::Tput::AlignFlag::Left, top = 0, left = 0, right = (@scrollbar ? 1 : 0), parse_tags = @parse_tags, height = 1, focus_on_click = false, normal_resizable = false, width = nil, alpha = style.alpha) # XXX hover_effects, focus_effects

        if @resizable || normal_resizable
          right = nil
        end

        item = Widget::Box.new(content: content, screen: screen, align: align, top: top, left: left, right: right, parse_tags: parse_tags, height: 1, focus_on_click: focus_on_click, width: width, style: style)
        # XXX above: alpha

        # TODO Mouse
        # if @mouse
        # end

        emit Crysterm::Event::CreateItem

        item
      end

      def append_item(content : String)
        item = create_item content
        item.top = @items.size

        @ritems.push content
        invalidate_item_index
        @items.push item
        append item

        if @items.size == 1
          selekt 0
        end

        emit ::Crysterm::Event::AddItem

        item
      end

      def append_item(widget : Widget)
        append_item widget.get_content
      end

      def remove_item(child : Widget)
        i = get_item_index child
        return unless i >= 0

        if item = @items[i]?
          child = @items.delete_at i
          @ritems.delete_at i
          invalidate_item_index
          remove child
        end

        j = i
        while j < @items.size
          pt = @items[j].top.as(Int) - 1
          @items[j].top = pt
          j += 1
        end

        if i == selected
          selekt i - 1
        end

        emit ::Crysterm::Event::RemoveItem

        item
      end

      def get_item(child : Widget)
        i = get_item_index child
        return nil unless i >= 0
        @items[i]?
      end

      def get_item_index(child : Int)
        child
      end

      def get_item_index(child : String)
        # Exact (raw, tags-included) match takes priority, matching the
        # previous behavior.
        i = @ritems.index child
        return i if i

        # Fallback: match against the tag-stripped form of each item. The
        # cleaned->index map is built once and reused until `@ritems` changes,
        # instead of re-cleaning every item on each call. First index wins, as
        # the previous linear scan did.
        index = @clean_tags_index ||= begin
          h = {} of String => Int32
          @ritems.each_with_index do |item, idx|
            cleaned = clean_tags item
            h[cleaned] = idx unless h.has_key? cleaned
          end
          h
        end
        index[child]? || -1
      end

      # Drops the cached `clean_tags` index. Called from every method that
      # mutates `@ritems` so the lazily-rebuilt map can never go stale.
      private def invalidate_item_index
        @clean_tags_index = nil
      end

      # Accepts any `Widget` (not only `Widget::Box`) so that callers holding
      # a `child : Widget` resolve here. Returns -1 when not found, matching
      # the `Int`/`String` overloads and the `>= 0` checks in callers.
      def get_item_index(child : Widget)
        (@items.index child) || -1
      end

      def selekt(index : Int)
        return unless interactive?

        if @items.empty?
          @selected = 0
          @value = ""
          scroll_to 0
          return
        end

        # XXX change this to more thread & bug safe code.

        if index < 0
          index = 0
        elsif index >= @items.size
          index = @items.size - 1
        end

        return if @selected == index && @_list_initialized
        @_list_initialized = true

        @selected = index
        @value = clean_tags @ritems[@selected]

        # Gate the scroll + `SelectItem` emit on having been laid out, not on
        # having a `#parent`. A top-level widget appended straight to a `Screen`
        # has no `#parent` (a `Screen` is not a `Widget`; `Screen#insert` sets
        # `screen=`, not `parent=`), so the old `unless @parent` guard silently
        # skipped `scroll_to`/`SelectItem` for every screen-level list — the
        # list would never scroll to keep the selection visible, nor notify
        # listeners. `@lpos` is nil only until the first render (when scrolling
        # can't be computed anyway), and set thereafter for parented and
        # top-level widgets alike.
        return unless @lpos

        scroll_to @selected

        emit ::Crysterm::Event::SelectItem, @items[@selected], @selected
      end

      def selekt(widget : Widget)
        if i = @items.index(widget)
          selekt i
        end
      end

      def clear_items
        # XXX set_items [] of
      end

      def push_item(content)
        append_item content
        @items.size
      end

      def pop_item
        return if @items.empty?
        # `remove_item` only accepts a `Widget`; pass the last item itself
        # rather than an `Int` index (which matches no overload).
        remove_item @items[-1]
      end

      def unshift_item(content)
        insert_item 0, content
        @items.size
      end

      def shift_item
        return if @items.empty?
        remove_item @items[0]
      end

      def move(offset)
        selekt selected + offset
      end

      def up(offset = 1)
        move -offset
      end

      def down(offset = 1)
        move offset
      end

      def insert_item(child, content : String)
        i = get_item_index child
        return unless i >= 0
        if i >= @items.size
          return append_item content
        end
        item = create_item content
        j = i
        while j < @items.size
          @items[j].top = @items[j].top.as(Int) + 1
          j += 1
        end
        item.top = i
        @ritems.insert i, content
        invalidate_item_index
        @items.insert i, item
        append item
        if i == selected
          selekt i + 1
        end
        emit Crysterm::Event::InsertItem
      end

      def set_item(child, content : String)
        # TODO In these places where index is received, make it receive both index and element,
        # so that we don't modify the wrong element later.
        i = get_item_index child
        return unless i >= 0

        @items[i]?.try &.set_content(content)
        if i < @ritems.size
          @ritems[i] = content
          invalidate_item_index
        end
      end

      def set_item(child, widget : Widget)
        set_item child, content: widget.get_content
      end

      def set_items(items)
        original = @items.dup
        selekted = selected
        sel = @ritems[selekted]?

        selekt 0

        items.each_with_index do |item, i|
          if itm = @items[i]?
            itm.set_content item
          else
            append_item item
          end
        end

        # Remove only the *leftover* original items (those past the end of the
        # new list). The first `items.size` originals were reused above via
        # `set_content`, so removing them too (as the old `original.each` did)
        # detached the very widgets we just repopulated. Also use `remove_item`,
        # not `remove`: `remove` only unlinks the widget from the children tree
        # and leaves `@items`/`@ritems` holding stale entries, desyncing them.
        if original.size > items.size
          original[items.size..].each do |itm|
            remove_item itm
          end
        end

        @ritems = items
        invalidate_item_index

        # Try to find our old item if it still exists
        if sel
          sel = items.index sel
          if sel
            selekt sel
          elsif @items.size == original.size
            # Use the saved selection (`selekted`); `selected` was just reset to
            # 0 by `selekt 0` above.
            selekt selekted
          else
            selekt Math.min selekted, @items.size - 1
          end
        end

        emit Crysterm::Event::SetItems
      end

      def enter_selected(i)
        selekt i
        enter_selected
      end

      def enter_selected
        emit Crysterm::Event::ActionItem, items[selected], selected
        emit Crysterm::Event::SelectItem, items[selected], selected
      end

      def cancel_selected(i)
        selekt i
        cancel_selected
      end

      def cancel_selected
        emit Crysterm::Event::ActionItem, items[selected], selected
        emit Crysterm::Event::CancelItem, items[selected], selected
      end

      # TODO
      # find
      # pick

      def on_keypress(e)
        case e.key
        when nil
        when ::Tput::Key::Up
          up
          screen.render
        when ::Tput::Key::Down
          down
          screen.render
        when ::Tput::Key::Enter
          enter_selected
        when ::Tput::Key::Escape
          cancel_selected
          # TODO other keys too
        end
      end

      def on_resize(e)
        visible = aheight - iheight
        if visible >= selected + 1
          @child_base = 0
          @child_offset = selected
        else
          # NOTE Is this supposed to be: child_base = visible - selected + 1
          @child_base = selected - visible + 1
          @child_offset = visible - 1
        end
      end

      def on_adopt(e)
        # unless @items.includes? el
        #  el.fixed = true
        # end
      end

      def on_remove(e)
        # XXX remove_item e.widget
      end
    end
  end
end
