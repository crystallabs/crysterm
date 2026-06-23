module Crysterm
  module Mixin
    # Identity hooks used by the CSS styling subsystem to match widgets against
    # selectors.
    #
    # A widget exposes three kinds of selector-matchable identity:
    #
    # * **Type names** (`#css_type_classes`) — the widget's class-hierarchy
    #   names, derived automatically. A `Widget::Button` yields
    #   `["Button", "Input", "Box", "Widget"]`. These are emitted as element
    #   classes, and the stylesheet parser rewrites a bare type selector like
    #   `Input` into the class selector `.Input` — so `Input { ... }` matches
    #   `Button` and every other `Input` subclass (Qt-style base matching),
    #   while the exact widget name is what the user writes. Computed at compile
    #   time (see the `inherited` hook); never changes at runtime.
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
          # The type chain, computed once at compile time and returned as a
          # shared constant. `#to_html` reads it for every widget on every
          # (dirty) document rebuild, so a fresh array per call would be needless
          # allocation churn. Treat it as read-only (don't mutate the result).
          CSS_TYPE_CLASSES = \{{ ([@type] + @type.ancestors).select(&.<=(::Crysterm::Widget)).map { |t| t.name.split("::").last }.uniq }}

          def css_type_classes : Array(String)
            CSS_TYPE_CLASSES
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
      # `inherited` hook above with their own full type chain. Shared constant —
      # treat as read-only.
      WIDGET_TYPE_CLASSES = ["Widget"]

      def css_type_classes : Array(String)
        WIDGET_TYPE_CLASSES
      end

      # The complete class list emitted for this widget in the CSS document:
      # the automatic type chain followed by any user-assigned classes. With no
      # user classes (the common case) the shared type-chain constant is returned
      # directly — no allocation. Callers must not mutate the result.
      def css_all_classes : Array(String)
        return css_type_classes if css_classes.empty?
        css_type_classes + css_classes.to_a
      end
    end
  end
end
