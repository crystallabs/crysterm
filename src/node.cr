require "event_handler"

module Crysterm
  # Base class that everything inherits from.
  # Only EventEmitter is lower-level than this.
  abstract class Node
    @@uid = 0

    include EventHandler

    # Unique ID. Auto-incremented.
    property uid : Int32

    # Widget::Screen owning this element.
    # Each element must belong to a Widget::Screen if it is to be rendered/displayed anywhere.
    property screen : Widget::Screen

    ######### COMMON WITH SCREEN

    # Node's children `Element`s.
    property children = [] of Widget::Element

    property? destroyed = false

    property? detached : Bool = false

    def append(element)
      insert element
    end

    def append(*elements)
      elements.each do |el|
        insert el
      end
    end

    def insert(element, i = -1)
      if element.screen != @screen
        raise Exception.new("Cannot switch a node's screen.")
      end

      element.detach

      element.screen = @screen

      # if i == -1
      #  @children.push element
      # elsif i == 0
      #  @children.unshift element
      # else
      @children.insert i, element
      # end

      element.parent = self
      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element

      emt = uninitialized Node -> Nil
      emt = ->(el : Node) {
        n = el.detached? != @detached
        el.detached = @detached
        el.emit Crysterm::Event::Attach if n
        el.children.each do |c|
          emt.call c
        end
      }
      emt.call element

      unless @screen.focused
        @screen.focused = element
      end
    end

    # Removes node from its parent.
    # This is identical to calling `#remove` on the parent object.
    def detach
      @parent.try { |p| p.remove self }
    end

    def remove(element)
      return if element.parent != self

      return unless i = @children.index(element)

      element.clear_pos

      element.parent = nil
      @children.delete_at i

      # TODO Enable
      # if i = @screen.clickable.index(element)
      #  @screen.clickable.delete_at i
      # end
      # if i = @screen.keyable.index(element)
      #  @screen.keyable.delete_at i
      # end

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)
      # s= @screen
      # raise Exception.new() unless s
      # screen_clickable= s.clickable
      # screen_keyable= s.keyable

      emt = ->(el : Node) {
        n = el.detached? != @detached
        el.detached = true
        # TODO Enable
        # el.emit(Event::Detach) if n
        # el.children.each do |c| c.emt end # wt
      }
      emt.call element

      if @screen.focused == element
        @screen.rewind_focus
      end
    end

    # Prepends node to the list of children
    def prepend(element)
      insert element, 0
    end

    # Adds node to the list of children before the specified `other` element
    def insert_before(element, other)
      if i = @children.index other
        insert element, i
      end
    end

    # Adds node to the list of children after the specified `other` element
    def insert_after(element, other)
      if i = @children.index other
        insert element, i + 1
      end
    end

    ######### END OF COMMON WITH SCREEN


    # Node's parent `Widget::Element`, if any.
    property parent : Widget::Element?

    # Element's render (order) index that was determined/used during the last `#render` call.
    property index = -1

    property name : String

    # Storage for any miscellaneous data.
    property data : JSON::Any?

    def initialize(
      @parent = nil,
      name = nil,
      @screen = determine_screen,
      index = -1,
      children = [] of Widget::Element
    )
      @uid = next_uid

      @name = name || "#{self.class.name}-#{@uid}"

      # $ = _ = JSON/YAML::Any

      @screen.try &.append self

      # Add element to either its parent, or some screen that is found.
      @parent.try do |parent|
        parent.append self
      end

      children.each do |child|
        append child
      end
    end

    def next_uid
      @@uid += 1
    end

    def determine_screen
      scr = if Widget::Screen.total <= 1
        # This will use the first screen or create one if none created yet.
        # (Auto-creation helps writing scripts with less code.)
        Widget::Screen.global true
      elsif s = @parent
        while s && !(s.is_a? Widget::Screen)
          s = s.parent_or_screen
        end
        if s.is_a? Widget::Screen
          s
        #else
        #  raise Exception.new("No active screen found in parent chain.")
        end
      elsif Widget::Screen.total > 0
        Widget::Screen.instances[-1]
      end

      unless scr
        raise Exception.new("No Widget::Screen found anywhere. Create one with Widget::Screen.new")
      end

      scr
    end

    # Returns parent `Element` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return nil if Widget::Screen === self
      @parent || @screen
    end

    def destroy
      @children.each do |c|
        c.destroy
      end
      detach
      @destroyed = true
      emit Crysterm::Event::Destroy
    end

    # TODO
    # get/set functions for data JSON

    # Moved here from screen. This is node's attribute.
    def _get_pos
      self
    end

    # Nop for the basic class
    def free
    end

    def has_ancestor?(obj)
      el = self
      while el = el.parent
        return true if el == obj
      end
      false
    end

    def has_descendant?(obj)
      @children.each do |el|
        return true if el == obj
        return true if el.has_descendant? obj
      end
      false
    end

    def each_descendant(with_self : Bool = false, &block : Proc(Node, Nil)) : Nil
      block.call(self) if with_self

      f = uninitialized Node -> Nil
      f = ->(el : Node) {
        block.call el
        el.children.each do |c|
          f.call c
        end
      }

      @children.each do |el|
        f.call el
      end
    end

    def each_ancestor(with_self : Bool = false) : Nil
      yield self if with_self

      el = self
      while el = el.parent
        yield el
      end
    end

    def collect_descendants(el : Node) : Array(Node)
      children = [] of Node
      each_descendant { |el| children << el }
      children
    end

    def collect_ancestors(el : Node) : Array(Node)
      parents = [] of Node
      each_ancestor { |el| parents << el }
      parents
    end

    # Emits `ev` on all children nodes, recursively.
    def emit_descendants(ev : EventHandler::Event) : Nil
      each_descendant { |el| el.emit ev }
    end

    # Emits `ev` on all parent nodes.
    def emit_ancestors(ev : EventHandler::Event) : Nil
      each_ancestor { |el| el.emit ev }
    end
  end
end
