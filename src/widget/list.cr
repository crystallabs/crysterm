module Crysterm
  class Widget
    class List < Widget
      property ignore_keys = true
      property scrollable = true

      property _list_initialized = false

      # property items = [] of Widget::Box # Already defined in widget.cr

      property ritems = [] of String
      property selected = 0

      # When true, a single mouse click on an item activates it (rather than the
      # default two-click select-then-activate). Set by `Widget::Menu`.
      property? activate_on_click : Bool = false

      # Whether more than one item can be selected at once, like Qt's
      # `QAbstractItemView::MultiSelection`. When on, Space toggles the current
      # item's membership in `#selected_indices` (the cursor still moves with the
      # arrow keys). When off, the list behaves as a single-selection list and
      # only the cursor item is highlighted.
      property? multi_select : Bool = false

      # Indices of the items that are part of the multi-selection (only
      # meaningful when `#multi_select?`). Maintained across insert/remove so the
      # marked items track their rows.
      getter selected_indices = Set(Int32).new

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

      # React to mouse: click an item to select it (click the selected one to
      # activate it), and scroll the selection with the wheel. Items are wired
      # for this in `#create_item` when enabled.
      property? mouse = true

      def initialize(input = true, mouse = true, multi_select = false, items : Enumerable(String)? = nil, **box)
        @mouse = mouse
        @multi_select = multi_select
        super **box, input: input, keys: true

        @value = ""

        items.try &.each { |item| append_item item }

        selekt 0

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

      # Resolves the `Style` an item box should render with. This is the single
      # entry point called from `Widget#_render`; subclasses (e.g.
      # `Widget::ListTable`, for alternating rows) override it.
      #
      # The cursor item gets the full `selected` highlight. In `#multi_select?`
      # mode the *other* checked items are underlined so they read as selected
      # without being confused with the cursor (Qt shows the current item and the
      # selected set distinctly).
      def render_style_for(item : Widget) : Style
        # If CSS styled this item (e.g. `List Box`, `Item:nth-child(even)`), use
        # the item's own cascade-computed style, reflecting selection through its
        # widget state so `:selected` rules apply.
        if item.css_styled?
          item.state = item_selected?(item) ? WidgetState::Selected : WidgetState::Normal
          return item.style
        end

        # Fast path (the overwhelmingly common case): no multi-selection, so the
        # only "selected" item is the cursor — an O(1) array compare, no scan.
        unless multi_select?
          return item_render_style(@items[@selected]? == item)
        end

        i = @items.index item
        return item_render_style(true) if i == @selected

        if i && @selected_indices.includes?(i)
          marked = item_render_style(false).dup
          marked.underline = true
          return marked
        end

        item_render_style false
      end

      # Whether *item* should render in the selected style: it is the cursor
      # item, or (in `#multi_select?` mode) it is part of `#selected_indices`.
      def item_selected?(item : Widget) : Bool
        # Fast path: single-selection lists only need an O(1) compare against the
        # cursor item (this runs once per item per frame from `Widget#_render`).
        return @items[@selected]? == item unless multi_select?

        i = @items.index item
        return false unless i
        i == @selected || @selected_indices.includes?(i)
      end

      # Tag-stripped text of every multi-selected item, in row order. In
      # single-selection mode this is just `[value]` (or `[]` when empty).
      def selected_values : Array(String)
        return [@value] unless multi_select?
        @selected_indices.to_a.sort.compact_map { |i| @ritems[i]?.try { |r| clean_tags r } }
      end

      # Adds *index* to the multi-selection (no-op unless `#multi_select?`).
      def select_item(index : Int)
        return unless multi_select?
        return unless 0 <= index < @items.size
        if @selected_indices.add?(index)
          emit ::Crysterm::Event::SelectItem, @items[index], index
        end
      end

      # Removes *index* from the multi-selection.
      def deselect_item(index : Int)
        @selected_indices.delete index
      end

      # Flips *index*'s membership in the multi-selection.
      def toggle_selection(index : Int)
        return unless multi_select?
        @selected_indices.includes?(index) ? deselect_item(index) : select_item(index)
      end

      # Clears the whole multi-selection.
      def clear_selection
        @selected_indices.clear
      end

      def create_item(content, screen = ::Crysterm::Screen.global, align : ::Tput::AlignFlag | Shorthands = ::Tput::AlignFlag::Left, top = 0, left = 0, right = (@scrollbar ? 1 : 0), parse_tags = @parse_tags, height = 1, focus_on_click = false, normal_resizable = false, width = nil, alpha = style.alpha) # XXX hover_effects, focus_effects

        if @resizable || normal_resizable
          right = nil
        end

        item = Widget::Box.new(content: content, screen: screen, align: align, top: top, left: left, right: right, parse_tags: parse_tags, height: 1, focus_on_click: focus_on_click, width: width, style: style)
        # XXX above: alpha

        if mouse?
          # By default a click selects the item and clicking the already-selected
          # one activates it (Blessed-style two-click). With `#activate_on_click?`
          # (used by menus) a single click both selects and activates.
          item.on(::Crysterm::Event::Click) do
            if i = @items.index item
              focus
              if activate_on_click? || i == @selected
                enter_selected i
              else
                selekt i
              end
              request_render
            end
          end

          # Wheel moves the selection (and `#accept`s the event so the screen's
          # default "scroll the view" behavior doesn't also fire).
          item.on(::Crysterm::Event::Mouse) do |e|
            if e.action.wheel_up?
              move -2
              e.accept
              request_render
            elsif e.action.wheel_down?
              move 2
              e.accept
              request_render
            end
          end
        end

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

        (i...@items.size).each { |j| @items[j].top = @items[j].top.as(Int) - 1 }

        # Keep the multi-selection aligned with the shifted rows: drop the removed
        # index and slide everything past it down by one.
        if @selected_indices.includes?(i) || @selected_indices.any? { |s| s > i }
          @selected_indices = @selected_indices.compact_map do |s|
            next nil if s == i
            s > i ? s - 1 : s
          end.to_set
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

        index = index.clamp(0, @items.size - 1)

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
        set_items [] of String
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
        (i...@items.size).each { |j| @items[j].top = @items[j].top.as(Int) + 1 }
        # Slide multi-selected indices at/after the insertion point up by one.
        if @selected_indices.any? { |s| s >= i }
          @selected_indices = @selected_indices.map { |s| s >= i ? s + 1 : s }.to_set
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
        # The row set is being replaced wholesale; stale indices can't be
        # meaningfully carried over, so drop the multi-selection.
        @selected_indices.clear
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

      # Enables the incremental-search prompt (`/` forward, `?` backward) in the
      # key handler.
      property? search = true

      # Lazily-created one-line input shown at the bottom of the screen during a
      # search (see `#start_search`).
      @search_box : Widget::TextBox? = nil

      # Index of the first item whose tag-stripped, case-insensitive text
      # contains *query*, scanning from the current selection and wrapping.
      # Returns the current selection when nothing matches. *back* searches
      # upward.
      def fuzzy_find(query : String, back = false) : Int32
        return selected if @items.empty?
        q = query.downcase
        n = @items.size
        step = back ? -1 : 1
        i = selected
        n.times do
          i = (i + step) % n
          i += n if i < 0
          return i if clean_tags(@ritems[i]).downcase.includes? q
        end
        selected
      end

      private def ensure_search_box : Widget::TextBox
        @search_box ||= begin
          box = Widget::TextBox.new(
            screen: screen,
            bottom: 0, left: 0, right: 0, height: 1,
            style: Style.new(bg: "blue", fg: "white"),
          )
          screen.append box
          box.hide
          box
        end
      end

      # Opens the incremental-search prompt. Typing a query and pressing Enter
      # jumps to the next matching item; Escape cancels. *back* searches upward.
      def start_search(back = false)
        return unless search?
        return if @items.empty?

        sb = ensure_search_box
        sb.set_label(back ? "?" : "/")
        sb.value = ""
        sb.show
        request_render

        sb.read_input do |_err, data|
          sb.hide
          focus
          if data && !data.empty?
            selekt fuzzy_find(data, back)
          end
          request_render
        end
      end

      # TODO
      # pick

      def on_keypress(e)
        visible = aheight - iheight
        half = Math.max visible // 2, 1

        case
        when e.key == ::Tput::Key::Up, (@vi && e.char == 'k')
          up
        when e.key == ::Tput::Key::Down, (@vi && e.char == 'j')
          down
        when e.key == ::Tput::Key::Home, (@vi && e.char == 'g')
          selekt 0
        when e.key == ::Tput::Key::End, (@vi && e.char == 'G')
          selekt @items.size - 1
        when e.key == ::Tput::Key::CtrlU
          move -half
        when e.key == ::Tput::Key::CtrlD
          move half
        when e.key == ::Tput::Key::PageUp, e.key == ::Tput::Key::CtrlB
          move -visible
        when e.key == ::Tput::Key::PageDown, e.key == ::Tput::Key::CtrlF
          move visible
        when @vi && e.char == 'H'
          selekt @child_base
        when @vi && e.char == 'M'
          selekt @child_base + visible // 2
        when @vi && e.char == 'L'
          selekt @child_base + visible - 1
        when search? && e.char == '/'
          start_search false
        when search? && e.char == '?'
          start_search true
        when multi_select? && e.char == ' '
          toggle_selection selected
        when e.key == ::Tput::Key::Enter
          enter_selected
        when e.key == ::Tput::Key::Escape
          cancel_selected
        else
          return
        end

        # A key we handled: consume it (so it doesn't also drive an ancestor,
        # e.g. a `Form`'s own vi `j`/`k`) and repaint.
        e.accept
        request_render
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
