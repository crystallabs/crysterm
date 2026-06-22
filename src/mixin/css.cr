module Crysterm
  module Mixin
    # Identity hooks used by the CSS styling subsystem to match widgets against
    # selectors.
    #
    # A widget exposes three kinds of selector-matchable identity:
    #
    # * **Type classes** (`#css_type_classes`) — derived automatically from the
    #   widget's class hierarchy. A `Widget::Button` yields
    #   `["w-button", "w-input", "w-box", "w-widget"]`, so a rule like
    #   `.w-input { ... }` matches `Button` and every other `Input` subclass.
    #   These are computed at compile time (see the `inherited` hook) and never
    #   change at runtime.
    # * **User classes** (`#css_classes`) — an arbitrary, mutable set the user
    #   assigns, matched by `.name` selectors just like HTML classes.
    # * **CSS id** (`#css_id`) — an optional, user-facing, *semantic* id matched
    #   by `#name` selectors. It is deliberately separate from the internal
    #   numeric `#uid`: `uid` is the stable node->widget writeback key (emitted
    #   as a `data-uid` attribute in the CSS document), whereas `css_id` is for
    #   humans and may be left unset.
    module Css
      macro included
        # Generate a hierarchy-specific `#css_type_classes` for every subclass.
        # `@type.ancestors` is filtered to the `Widget` chain so unrelated
        # mixin/`EventHandler` ancestors don't leak in, and each class name's
        # leaf is lowercased into a `w-`-prefixed token.
        macro inherited
          def css_type_classes : Array(String)
            \{{ ([@type] + @type.ancestors).select(&.<=(::Crysterm::Widget)).map { |t| "w-" + t.name.split("::").last.downcase }.uniq }}
          end
        end
      end

      # Optional, user-facing semantic id, matched by `#id` CSS selectors.
      # Separate from the internal `#uid`; see the module docs.
      getter css_id : String?

      # Assigns the CSS id, invalidating styling so the change is reflected.
      def css_id=(@css_id : String?) : String?
        invalidate_css
        @css_id
      end

      # Arbitrary user-assigned classes, matched by `.class` CSS selectors.
      #
      # Reading is fine, but mutate through `#add_css_class`/`#remove_css_class`/
      # `#toggle_css_class` so styling is invalidated — a direct `<<`/`delete` on
      # the returned set will not trigger a restyle.
      getter css_classes = Set(String).new

      # Adds a CSS class and invalidates styling (no-op if already present).
      def add_css_class(name : String) : Nil
        return if @css_classes.includes? name
        @css_classes << name
        invalidate_css
      end

      # Removes a CSS class and invalidates styling (no-op if absent).
      def remove_css_class(name : String) : Nil
        return unless @css_classes.includes? name
        @css_classes.delete name
        invalidate_css
      end

      # Toggles a CSS class (and invalidates styling).
      def toggle_css_class(name : String) : Nil
        @css_classes.includes?(name) ? remove_css_class(name) : add_css_class(name)
      end

      # Base implementation for `Widget` itself. Subclasses override this via the
      # `inherited` hook above with their own full type chain.
      def css_type_classes : Array(String)
        ["w-widget"]
      end

      # The complete class list emitted for this widget in the CSS document:
      # the automatic type chain followed by any user-assigned classes.
      def css_all_classes : Array(String)
        css_type_classes + css_classes.to_a
      end
    end
  end
end
