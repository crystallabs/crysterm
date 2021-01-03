require "event_handler"
require "./element/position"
require "./element/rendering"

module Crysterm
  module Widget

    # Base class that everything inherits from.
    # Only EventEmitter is lower-level than this.
    abstract class Node
      @@uid= 0

      include EventHandler

      property? destroyed = false

      property screen : Screen
      property parent : Node?
      property uid : Int32

      property children = [] of Element

      getter type = :node

      property? detached : Bool = false

      property index = -1

      def initialize(
        screen = nil,
        @parent = nil,
        index = -1,
        children = [] of Element
      )
        @uid = next_uid

        @screen = screen || determine_screen

        # $ = _ = JSON/YAML::Any

        if @type != :screen
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
          s= @parent
          while s  && (s.type != :screen)
            s = s.parent
          end
          if s.is_a? Screen
            s
          else
            raise Exception.new("No active screen found in parent chain.");
          end
        elsif Screen.total > 0
          Screen.instances[-1]
        else
          raise Exception.new("No active screen found anywhere.");
        end
      end

      def append(element)
        insert element, @children.size
      end

      def insert(element, i=-1)
        if element.is_a? Screen
         return
        end

        # TODO Enable
        #if element.screen != @screen
        #  raise Exception.new("Cannot switch a node's screen.");
        #end

        element.detach
        element.parent = self

        element.screen = @screen # Isn't it already?

        @children.insert i, element

        # TODO Enable
        #element.emit(ReparentEvent, self);
        #emit(AdoptEvent, element);

        emt = ->(el : Node) {
          n = el.detached? != @detached
          el.detached = @detached
          # TODO Enable
          #el.emit(AttachEvent) if n
          #el.children.each do |c| c.emt end # wt
        }
        emt.call element
        #(function emit(el)
        #  var n = el.detached != self.detached;
        #  el.detached = self.detached;
        #  if (n) el.emit("attach");
        #  el.children.forEach(emit);
        #})(element);

        # TODO enable
        #unless @screen.focused
        #  @screen.focused = element
        #end
      end

      def detach
        @parent.try { |p| p.remove self }
      end

      def remove(element)
        return if element.parent != self

        return unless i = @children.index(element)

        # TODO Enable
        #element.clear_pos();

        element.parent = nil
        @children.delete_at i

        # TODO Enable
        #if i = @screen.clickable.index(element)
        #  @screen.clickable.delete_at i
        #end
        #if i = @screen.keyable.index(element)
        #  @screen.keyable.delete_at i
        #end

        # TODO Enable
        #element.emit(ReparentEvent, nil)
        #emit(RemoveEvent, element);

        #s= @screen
        #raise Exception.new() unless s
        #screen_clickable= s.clickable
        #screen_keyable= s.keyable

        emt = ->(el : Node) {
          n = el.detached? != @detached
          el.detached = true
          # TODO Enable
          #el.emit(DetachEvent) if n
          #el.children.each do |c| c.emt end # wt
        }
        emt.call element

        # TODO Enable
        #if @screen.focused == element
        #  @screen.rewind_focus
        #end
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
        # TODO Enable
        #emit DestroyedEvent
      end

      # TODO
      # get/set functions for data JSON

      # Moved here from screen. This is node's attribute.
      def _get_pos
        self
      end


#      EventHandler.event ReparentEvent, node : Node?
#      EventHandler.event AdoptEvent, node : Node
#      EventHandler.event RemoveEvent, node : Node
#
##      property :parent, :screen, :detached
#
##      #def self.uid; @@uid end
##      #def self.uid=( i); @@uid= i end
#
##
##      @data : String?
#
#
#
##      def free()
##        return;
##      end
##
###
###def forDescendants(iter, s)
###  if (s) iter(self);
###  @children.forEach(function emit(el)
###    iter(el);
###    el.children.forEach(emit);
###  });
###};
###
###def forAncestors(iter, s)
###  var el = self;
###  if (s) iter(self);
###  while (el = el.parent)
###    iter(el);
###  }
###};
###
###def collectDescendants(s)
###  var out = [];
###  @forDescendants(function(el)
###    out.push(el);
###  }, s);
###  return out;
###};
###
###def collectAncestors(s)
###  var out = [];
###  @forAncestors(function(el)
###    out.push(el);
###  }, s);
###  return out;
###};
###
###def emitDescendants()
###  var args = Array.prototype.slice(arguments)
###    , iter;
###
###  if (typeof args[args.size - 1] == "function")
###    iter = args.pop();
###  }
###
###  return @forDescendants(function(el)
###    if (iter) iter(el);
###    el.emit.apply(el, args);
###  }, true);
###};
###
###def emitAncestors()
###  var args = Array.prototype.slice(arguments)
###    , iter;
###
###  if (typeof args[args.size - 1] == "function")
###    iter = args.pop();
###  }
###
###  return @forAncestors(function(el)
###    if (iter) iter(el);
###    el.emit.apply(el, args);
###  }, true);
###};
###
###def hasDescendant(target)
###  return (function find(el)
###    for (var i = 0; i < el.children.size; i++)
###      if (el.children[i] == target)
###        return true;
###      }
###      if (find(el.children[i]) == true)
###        return true;
###      }
###    }
###    return false;
###  })(self);
###};
###
###def hasAncestor(target)
###  var el = self;
###  while (el = el.parent)
###    if (el == target) return true;
###  }
###  return false;
###};
###
###def get(name, value)
###  if (@data.hasOwnProperty(name))
###    return @data[name];
###  }
###  return value;
###};
###
###def set(name, value)
###  return @data[name] = value;
###};

    end
  end
end

#require "./screen"
#
#s = Crysterm::Widget::Screen.new
#
#class X < Crysterm::Widget::Node
#  def initialize(**arg)
#    super **arg
#  end
#end
#class Y < Crysterm::Widget::Node
#  def initialize(**arg)
#    super **arg
#  end
#end
#a = X.new
#b= Y.new
#
##p a
##p b
#s = Crysterm::Widget::Screen.global
#
#s.render
#s.draw
#sleep 2
#s.leave
#

