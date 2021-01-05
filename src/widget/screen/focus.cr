module Crysterm
  module Widget
    class Screen < Node
      module Focus
        include Crystallabs::Helpers::Alias_Methods

        def focus_offset(offset)
          shown = @keyable.select{ |el| !el.detached? && el.visible? }.size

          if (shown==0 || offset ==0)
            return
          end

          i = @keyable.index(@focused) || return

          if (offset > 0)
            while offset > 0
              offset -= 1
              i += 1
              if (i > @keyable.size - 1)
                i = 0
              end
              if (@keyable[i].detached? || !@keyable[i].visible?)
                offset += 1
              end
            end
          else
            offset = -offset
            while offset > 0
              offset -= 1
              i -= 1
              if (i < 0)
                i = @keyable.size - 1
              end
              if (@keyable[i].detached? || !@keyable[i].visible?)
                offset += 1
              end
            end
          end

          @keyable[i].focus
        end

        def focus_previous
          focus_offset -1
        end
        alias_previous focus_prev

        def focus_next
          focus_offset 1
        end

        def save_focus
          @_saved_focus = @focused
        end

        def restore_focus
          return unless sf = @_saved_focus
          sf.focus
          @_saved_focus = nil
          @focused
        end

      end
    end
  end
end

#focusPush = function(el)
#  if (!el) return
#  var old = @history[@history.size - 1]
#  if (@history.size === 10)
#    @history.shift()
#  }
#  @history.push(el)
#  _focus(el, old)
#}
#
#def focus_pop
#  var old = @history.pop()
#  if (@history.size)
#    _focus(@history[@history.size - 1], old)
#  }
#  return old
#end


#rewindFocus = function()
#  var old = this.history.pop()
#    , el
#
#  while (this.history.size)
#    el = this.history.pop()
#    if (!el.detached && el.visible)
#      this.history.push(el)
#      this._focus(el, old)
#      return el
#    }
#  }
#
#  if (old)
#    old.emit('blur')
#  }
#}
#
#_focus = function(self, old)
#  // Find a scrollable ancestor if we have one.
#  var el = self
#  while (el = el.parent)
#    if (el.scrollable) break
#  }
#
#  // If we're in a scrollable element,
#  // automatically scroll to the focused element.
#  if (el && !el.detached)
#    // NOTE: This is different from the other "visible" values - it needs the
#    // visible height of the scrolling element itself, not the element within
#    // it.
#    var visible = self.screen.height - el.atop - el.itop - el.abottom - el.ibottom
#    if (self.rtop < el.childBase)
#      el.scrollTo(self.rtop)
#      self.screen.render()
#    } else if (self.rtop + self.height - self.ibottom > el.childBase + visible)
#      // Explanation for el.itop here: takes into account scrollable elements
#      // with borders otherwise the element gets covered by the bottom border:
#      el.scrollTo(self.rtop - (el.height - self.height) + el.itop, true)
#      self.screen.render()
#    }
#  }
#
#  if (old)
#    old.emit('blur', self)
#  }
#
#  self.emit('focus', old)
#}
#
#__defineGetter__('focused', function()
#  return this.history[this.history.size - 1]
#})
#
#__defineSetter__('focused', function(el)
#  return this.focusPush(el)
#})
