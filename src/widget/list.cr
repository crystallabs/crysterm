module Crysterm
  class Widget
    class List < Widget
      property ignore_keys = true
      property scrollable = true

      property _list_initialized = false

      # property items = [] of Widget::Box # Already defined in widget.cr

      property ritems = [] of String
      property selected = 0

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
          on(::Crysterm::Event::KeyPress) do |e|
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
        end

        on(::Crysterm::Event::Resize) do
          visible = height - iheight
          if visible >= selected + 1
            @child_base = 0
            @child_offset = selected
          else
            # NOTE Is this supposed to be: child_base = visible - selected + 1
            @child_base = selected - visible + 1
            @child_offset = visible - 1
          end
        end
        on(::Crysterm::Event::Adopt) do # |e|
        # unless @items.includes? el
        #  el.fixed = true
        # end
        end
        on(::Crysterm::Event::Remove) do # |e|
        # XXX remove_item e.widget
        end
      end

      def create_item(content, screen = ::Crysterm::Screen.global, align = ::Tput::AlignFlag::Left, top = 0, left = 0, right = (@scrollbar ? 1 : 0), parse_tags = @parse_tags, height = 1, auto_focus = false, normal_resizable = false, width = nil, transparency = @style.transparency) # XXX hover_effects, focus_effects

        unless @auto_padding
          top = 1
          left = ileft
          right = iright + (@scrollbar ? 1 : 0)
        end

        if @resizable || normal_resizable
          right = nil
          width = "resizable"
        end

        item = Widget::Box.new(content: content, screen: screen, align: align, top: top, left: left, right: right, parse_tags: parse_tags, height: 1, auto_focus: auto_focus, width: width, style: style)
        # XXX above: transparency

        # TODO Mouse
        # if @mouse
        # end

        emit Crysterm::Event::CreateItem

        item
      end

      def append_item(content : String)
        item = create_item content
        item.position.top = @items.size
        unless @auto_padding
          item.position.top = itop + @items.size
        end

        @ritems.push content
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
        if i && (item = @items[i]?)
          child = @items.delete_at i
          @ritems.delete_at i
          remove child
        end

        j = i
        while j < @items.size
          @items[j].position.top -= 1
          j += 1
        end

        if i == selected
          selekt i - 1
        end

        emit ::Crysterm::Event::RemoveItem

        item
      end

      def get_item(child)
        @items[get_item_index child]?
      end

      def get_item_index(child : Int)
        return child
      end

      def get_item_index(child : String)
        i = @ritems.index child
        return i if i
        @ritems.each_with_index do |item, i|
          if child == clean_tags item
            return i
          end
          return -1
        end
      end

      def get_item_index(child : Widget::Box)
        @items.index child
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

        return unless @parent

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
        remove_item @items.size - 1
      end

      def unshift_item(content)
        insert_item 0, content
        @items.size
      end

      def shift_item
        remove_item 0
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
          @items[j].position.top += 1
          j += 1
        end
        item.position.top = i + (@auto_padding ? 0 : 1)
        @ritems.insert i, content
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
        @ritems[i]?.try &= (content)
      end

      def set_item(child, widget : Widget)
        set_item child, content: widget.get_content
      end

      def set_items(items)
        original = @items.dup
        selekted = selected
        sel = @ritems[selekted]?
        i = 0

        selekt 0

        items.each_with_index do |item, i|
          if itm = @items[i]?
            itm.set_content item
          else
            append_item item
          end
        end

        original.each do |item|
          remove item
        end

        @ritems = items

        # Try to find our old item if it still exists
        if sel
          sel = items.index sel
          if sel
            selekt sel
          elsif @items.size == original.size
            selekt selected
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

      # TOOD
      # find
      # pick
    end
  end
end
