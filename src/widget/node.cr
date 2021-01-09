require "event_handler"
require "./element/position"
require "./element/rendering"

module Crysterm
  # Base class that everything inherits from.
  # Only EventEmitter is lower-level than this.
  abstract class Node
    @@uid = 0

    include EventHandler

    property? destroyed = false

    property screen : Screen
    property parent : Node?
    property uid : Int32

    property children = [] of Element

    property? detached : Bool = false

    property index = -1

    property name : String

    def initialize(
      name = nil,
      screen = nil,
      @parent = nil,
      index = -1,
      children = [] of Element
    )
      @uid = next_uid

      @name = name || "#{self.class.name}-#{@uid}"

      @screen = screen || determine_screen

      # $ = _ = JSON/YAML::Any

      if !(is_a? Screen)
        @detached = true
      end

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
      if Screen.total == 1
        Screen.global
      elsif @parent
        s = @parent
        while s && !(s.is_a? Screen)
          s = s.parent
        end
        if s.is_a? Screen
          s
        else
          raise Exception.new("No active screen found in parent chain.")
        end
      elsif Screen.total > 0
        Screen.instances[-1]
      else
        raise Exception.new("No active screen found anywhere.")
      end
    end

    def append(element)
      insert element, @children.size
    end

    def append(*elements)
      elements.each do |el|
        insert el, @children.size
      end
    end

    def insert(element, i = -1)
      if element.is_a? Screen
        return
      end

      if element.screen != @screen
        raise Exception.new("Cannot switch a node's screen.")
      end

      element.detach
      element.parent = self

      element.screen = @screen # Isn't it already?

      # if i == -1
      #  @children.push element
      # elsif i == 0
      #  @children.unshift element
      # else
      @children.insert i, element
      # end

      element.emit(ReparentEvent, self)
      emit(AdoptEvent, element)
      emt = uninitialized Node -> Nil
      emt = ->(el : Node) {
        n = el.detached? != @detached
        el.detached = @detached
        el.emit(AttachEvent) if n
        el.children.each do |c|
          emt.call c
        end
      }
      emt.call element

      unless @screen.focused
        @screen.focused = element
      end
    end

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

      element.emit(ReparentEvent, nil)
      emit(RemoveEvent, element)
      # s= @screen
      # raise Exception.new() unless s
      # screen_clickable= s.clickable
      # screen_keyable= s.keyable

      emt = ->(el : Node) {
        n = el.detached? != @detached
        el.detached = true
        # TODO Enable
        # el.emit(DetachEvent) if n
        # el.children.each do |c| c.emt end # wt
      }
      emt.call element

      if @screen.focused == element
        @screen.rewind_focus
      end
    end

    def prepend(element)
      insert element, 0
    end

    def insert_before(element, other)
      if i = @children.index other
        insert element, i
      end
    end

    def insert_after(element, other)
      if i = @children.index other
        insert element, i + 1
      end
    end

    def destroy
      @children.each do |c|
        c.destroy
      end
      detach
      @destroyed = true
      emit DestroyEvent
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

    def each_descendant(with_self : Bool = false) : Nil
      yield self if with_self

      f = uninitialized Node -> Nil
      f = ->(el : Node) {
        yield el
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

    def emit_descendants(ev : EventHandler::Event) : Nil
      each_descendant { |el| el.emit ev }
    end

    def emit_ancestors(ev : EventHandler::Event) : Nil
      each_ancestor { |el| el.emit ev }
    end

  end
end
