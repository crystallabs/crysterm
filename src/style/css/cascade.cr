require "html5"

module Crysterm
  module CSS
    # Resolves a `Stylesheet` against a live widget tree and writes the computed
    # `Style`/`Styles` back onto each widget.
    #
    # The flow, per `#apply`:
    #
    # 1. Render the tree to the CSS document (`Screen#to_html`) and parse it.
    # 2. Index every node's `data-uid` back to its `Widget` (and sub-style slot).
    # 3. Match every rule with the `html5` selector engine exactly once (the
    #    document is state-independent), accumulating the matched declarations
    #    keyed by widget/slot/state and tagged with tier, specificity and order.
    #    `@media` rules whose condition doesn't match the terminal are skipped.
    #    A base rule is folded into `normal` plus only those states that have a
    #    state-specific rule; the rest lazily fall back to `normal`.
    # 4. Fold each accumulation (sorted by `{tier, specificity, order}`) onto a
    #    copy of the widget's existing style — default(0) < author(1) < inline
    #    `@style`(2) < `!important`(3) — so CSS overrides only what it specifies
    #    and leaves widget defaults intact. Geometry declarations write the
    #    widget itself (not the `Style`).
    # 5. Inherit the (inheritable) `color` down the tree where unset.
    #
    # Application is non-destructive and opt-in: only widget/state pairs a rule
    # actually matched are touched, and each is marked `css_styled` so `#style`
    # returns the computed (inline-folded) result.
    module Cascade
      # Cascade origin/priority tiers, lowest to highest. A declaration in a
      # higher tier always wins over a lower one regardless of specificity.
      TIER_DEFAULT   = 0 # default/UA stylesheet
      TIER_AUTHOR    = 1 # normal author rules
      TIER_INLINE    = 2 # inline `@style`
      TIER_IMPORTANT = 3 # `!important` declarations

      # An accumulated match: `{tier, specificity, order, declarations}`. Sorted
      # by `{tier, specificity, order}` so the winning declaration is applied
      # last.
      alias Entry = Tuple(Int32, Tuple(Int32, Int32, Int32), Int32, Hash(String, String))

      # Resolves the author *stylesheet* (plus the default stylesheet beneath it)
      # against the tree rooted at *screen*. *document* is the prebuilt CSS
      # document (`screen.to_html`); pass it to avoid rebuilding when the caller
      # already has it.
      def self.apply(stylesheet : Stylesheet, screen : Screen, doc : HTML5::Node, scope : Set(Widget)? = nil) : Nil
        apply_sheets([{CSS.default_stylesheet, TIER_DEFAULT}, {stylesheet, TIER_AUTHOR}], screen, doc, scope)
      end

      # Resolves a list of `{stylesheet, base_tier}` sources, lowest tier first,
      # against *screen*, matching against the pre-parsed *doc* (the screen owns
      # parsing and caches it). Higher tiers win regardless of specificity. When
      # *scope* is given, only widgets in that set have their styles recomputed
      # (incremental update); selector matching is still over the whole document
      # so ancestor/sibling context is correct.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.apply_sheets(sheets : Array(Tuple(Stylesheet, Int32)), screen : Screen, doc : HTML5::Node, scope : Set(Widget)? = nil) : Nil
        return if sheets.all?(&.[0].rules.empty?)

        index = index_tree(screen)

        # Match each distinct structural selector at most once per cascade (the
        # same selector can recur across tiers, states and `@media` blocks).
        selector_cache = Hash(String, Array(HTML5::Node)).new

        # Terminal metrics for `@media` evaluation.
        media_width = screen.width
        media_height = screen.height
        media_colors = begin
          screen.colors.to_i32
        rescue
          0x1000000
        end

        # Variables merge across sheets in order, so a later (higher-priority)
        # sheet's custom properties win.
        variables = {} of String => String
        sheets.each { |entry| variables.merge!(entry[0].variables) }

        # Match each rule against the document exactly once: the document is the
        # same in every state (state is carried on the rules, not the nodes), so
        # there is no need to re-run a selector per state. Base rules (no state
        # pseudo) are collected separately from state-specific rules so they can
        # be folded into only the states that are actually needed.
        base = Hash(String, Array(Entry)).new                    # key -> base entries
        acc = Hash(Tuple(String, WidgetState), Array(Entry)).new # {key, state} -> state entries
        stated_keys = Hash(String, Set(WidgetState)).new         # key -> states with own rules

        sheets.each do |(sheet, tier)|
          sheet.rules.each do |rule|
            next if rule.selector.empty?
            if mq = rule.media
              next unless mq.matches?(media_width, media_height, media_colors)
            end
            nodes = selector_cache.fetch(rule.selector) do
              matched = begin
                doc.css(rule.selector)
              rescue
                [] of HTML5::Node # ignore selectors the engine can't parse
              end
              selector_cache[rule.selector] = matched
            end
            # `:has(...)` — keep only nodes with a descendant matching the inner
            # selector (the engine has no native `:has`).
            if has = rule.has
              nodes = nodes.select { |node| has_descendant?(node, has) }
            end
            entries = rule_entries(rule, tier)
            next if entries.empty?
            nodes.each do |node|
              key = node["data-uid"]?.try(&.val)
              next unless key
              if state = rule.state
                (acc[{key, state}] ||= [] of Entry).concat entries
                (stated_keys[key] ||= Set(WidgetState).new) << state
              else
                (base[key] ||= [] of Entry).concat entries
              end
            end
          end
        end

        # Fold base entries into `normal` plus any state that has its own rules
        # for that key (so e.g. a focused style is `base + :focus`). States with
        # no rules are left to lazily fall back to `normal` at render time.
        base.each do |key, entries|
          states = stated_keys[key]?.try(&.dup) || Set(WidgetState).new
          states << WidgetState::Normal
          states.each { |state| (acc[{key, state}] ||= [] of Entry).concat entries }
        end

        touched = Set(Tuple(String, WidgetState)).new
        acc.each_key { |(key, state)| touched << {key.partition("::")[0], state} }

        # Reset every recomputed widget to its pristine pre-CSS styles before
        # (re)applying rules. This is what makes the cascade non-stale: a widget
        # that stopped matching a rule, or whose *inherited* value changed,
        # starts clean rather than building on its previous computed styles.
        # (Inherited-into widgets aren't `css_styled`, so every candidate is
        # reset, not just matched ones.)
        recompute_candidates(index, scope).each do |widget|
          widget.styles = widget.css_base_styles.deep_dup
          widget.css_styled = false
        end

        # Give every touched (widget, state) its own `Style` up front (a fresh
        # pristine dup). A state that otherwise lazily falls back to `normal`
        # would, if mutated in place by a sub-element rule, leak into `normal`.
        touched.each do |(uid, state)|
          if target = index[uid]?
            next unless scope.nil? || scope.includes?(target[0])
            set_state_style target[0], state, base_state_style(target[0], state)
          end
        end

        # Apply each touched widget's main style: author/default declarations,
        # then the inline `@style` (tier 2), then `!important` (tier 3). Every
        # touched widget is processed (even one matched only via a sub-element)
        # so its inline style still folds into the main style, and is marked
        # `css_styled` so `#style` returns the computed result. Out-of-scope
        # widgets keep their already-computed styles (incremental update).
        touched.each do |(uid, state)|
          next unless target = index[uid]?
          widget = target[0]
          next unless scope.nil? || scope.includes?(widget)
          entries = acc[{uid, state}]? || EMPTY_ENTRIES
          apply_entries_with_inline get_state_style(widget, state), entries, variables, widget.css_inline_style
          # Geometry/layout is a single per-widget concern, not per-state, so
          # apply it once from the (now sorted) normal-state entries.
          apply_geometry widget, entries, variables if state.normal?
          widget.css_styled = true
        end

        # Sub-element styles build on the now-current per-state style.
        acc.each do |(key, state), entries|
          next unless key.includes?("::")
          next unless target = index[key]?
          widget, slot = target
          next unless scope.nil? || scope.includes?(widget)
          state_style = get_state_style(widget, state)
          sub = get_sub_style(state_style, slot).dup
          apply_entries sub, entries, variables
          set_sub_style state_style, slot, sub
        end

        inherit screen
      end

      EMPTY_ENTRIES = [] of Entry

      # Whether *node* has a descendant (or, with `:scope`, relative element)
      # matching the `:has(...)` inner selector.
      private def self.has_descendant?(node : HTML5::Node, inner : String) : Bool
        !node.css(inner).empty?
      rescue
        false
      end

      # The cascade entries a rule contributes: its normal declarations at
      # *base_tier*, and its `!important` declarations at `TIER_IMPORTANT`.
      private def self.rule_entries(rule : Rule, base_tier : Int32) : Array(Entry)
        entries = [] of Entry
        entries << {base_tier, rule.specificity, rule.order, rule.declarations} unless rule.declarations.empty?
        entries << {TIER_IMPORTANT, rule.specificity, rule.order, rule.important} unless rule.important.empty?
        entries
      end

      # Folds *entries* onto *style* in place, in cascade order
      # (`{tier, specificity, order}`, so the winning declaration applies last).
      # `var(...)` references in values are resolved against *variables*.
      private def self.apply_entries(style : Style, entries : Array(Entry), variables : Hash(String, String)) : Nil
        entries.sort_by! { |entry| {entry[0], entry[1], entry[2]} }
        entries.each { |entry| apply_decls style, entry[3], variables }
      end

      # Like `apply_entries`, but interleaves the inline `@style` at
      # `TIER_INLINE`: entries below that tier (default + author) apply first,
      # then the inline style, then entries at/above it (`!important`). So inline
      # outranks normal author rules but `!important` outranks inline.
      private def self.apply_entries_with_inline(style : Style, entries : Array(Entry), variables : Hash(String, String), inline : Style?) : Nil
        entries.sort_by! { |entry| {entry[0], entry[1], entry[2]} }
        i = 0
        while i < entries.size && entries[i][0] < TIER_INLINE
          apply_decls style, entries[i][3], variables
          i += 1
        end
        fold_inline style, inline if inline
        while i < entries.size
          apply_decls style, entries[i][3], variables
          i += 1
        end
      end

      private def self.apply_decls(style : Style, declarations : Hash(String, String), variables : Hash(String, String)) : Nil
        declarations.each do |property, value|
          Properties.apply(style, property, Stylesheet.resolve_var(value, variables))
        end
      end

      # Applies geometry/layout declarations (width/height/position/text-align)
      # onto the widget itself, from *entries* in cascade order (last wins). The
      # entries are already sorted by the caller.
      private def self.apply_geometry(widget : Widget, entries : Array(Entry), variables : Hash(String, String)) : Nil
        entries.each do |entry|
          entry[3].each do |property, value|
            Geometry.apply(widget, property, Stylesheet.resolve_var(value, variables)) if Geometry.handles?(property)
          end
        end
      end

      # Folds an inline `@style`'s explicitly-set properties onto *style*. Each
      # property is copied only if the inline style `specified?` it — so inline
      # can switch a text attribute either on *or* off over a stylesheet.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      private def self.fold_inline(style : Style, inline : Style) : Nil
        style.fg = inline.fg if inline.specified?(:fg)
        style.bg = inline.bg if inline.specified?(:bg)
        style.bold = inline.bold? if inline.specified?(:bold)
        style.italic = inline.italic? if inline.specified?(:italic)
        style.underline = inline.underline? if inline.specified?(:underline)
        style.blink = inline.blink? if inline.specified?(:blink)
        style.inverse = inline.inverse? if inline.specified?(:inverse)
        style.alpha = inline.alpha if inline.specified?(:alpha)
        style.border = inline.border if inline.border.any?    # ameba:disable Performance/AnyInsteadOfEmpty
        style.padding = inline.padding if inline.padding.any? # ameba:disable Performance/AnyInsteadOfEmpty
        style.shadow = inline.shadow if inline.shadow.any?    # ameba:disable Performance/AnyInsteadOfEmpty
      end

      # The widgets eligible to be reset/recomputed: every (main) widget in the
      # document index, intersected with *scope* when scoped. Intersecting with
      # the index guarantees the cascade only ever touches *this* screen's
      # widgets — a `scope` could otherwise include a widget that has since moved
      # to another screen (a stale dirty-subtree root).
      private def self.recompute_candidates(index, scope : Set(Widget)?) : Enumerable(Widget)
        widgets = Set(Widget).new
        index.each_value { |(widget, slot)| widgets << widget if slot.nil? }
        scope ? (widgets & scope) : widgets
      end

      # Walks the widget tree, mapping each `data-uid` key (and each sub-element
      # `uid::slot` key) back to its `{widget, slot}`.
      private def self.index_tree(screen : Screen) : Hash(String, Tuple(Widget, String?))
        index = {} of String => Tuple(Widget, String?)
        screen.children.each { |child| index_widget child, index }
        index
      end

      private def self.index_widget(widget : Widget, index) : Nil
        index[widget.uid.to_s] = {widget, nil}
        widget.css_sub_elements.each do |slot|
          index["#{widget.uid}::#{slot}"] = {widget, slot}
        end
        widget.children.each { |child| index_widget child, index }
      end

      # Inherits the classically-inherited properties — `color` (fg),
      # `font-weight` (bold), `font-style` (italic) and `visibility` (visible) —
      # down the tree wherever a widget's normal style leaves them unset. Runs
      # pre-order so a parent's resolved value is available to its children, and
      # so an inherited value re-propagates to grandchildren.
      private def self.inherit(screen : Screen) : Nil
        screen.children.each { |child| inherit_into child, nil }
      end

      private def self.inherit_into(widget : Widget, parent : Style?) : Nil
        normal = widget.styles.normal
        if parent
          normal.fg = parent.fg if !normal.specified?(:fg) && parent.specified?(:fg)
          normal.bold = parent.bold? if !normal.specified?(:bold) && parent.specified?(:bold)
          normal.italic = parent.italic? if !normal.specified?(:italic) && parent.specified?(:italic)
          normal.visible = parent.visible? if !normal.specified?(:visible) && parent.specified?(:visible)
        end
        widget.children.each { |child| inherit_into child, normal }
      end

      # --- per-state style accessors -----------------------------------------

      # A fresh dup of the widget's pristine (pre-CSS) style for *state* — the
      # clean base the cascade applies declarations onto.
      private def self.base_state_style(widget : Widget, state : WidgetState) : Style
        base = widget.css_base_styles
        style = case state
                in .normal?   then base.normal
                in .blurred?  then base.blurred
                in .focused?  then base.focused
                in .hovered?  then base.hovered
                in .selected? then base.selected
                in .disabled? then base.disabled
                end
        style.dup
      end

      private def self.get_state_style(widget : Widget, state : WidgetState) : Style
        case state
        in .normal?   then widget.styles.normal
        in .blurred?  then widget.styles.blurred
        in .focused?  then widget.styles.focused
        in .hovered?  then widget.styles.hovered
        in .selected? then widget.styles.selected
        in .disabled? then widget.styles.disabled
        end
      end

      private def self.set_state_style(widget : Widget, state : WidgetState, style : Style) : Nil
        case state
        in .normal?   then widget.styles.normal = style
        in .blurred?  then widget.styles.blurred = style
        in .focused?  then widget.styles.focused = style
        in .hovered?  then widget.styles.hovered = style
        in .selected? then widget.styles.selected = style
        in .disabled? then widget.styles.disabled = style
        end
      end

      # --- sub-style slot accessors ------------------------------------------

      private def self.get_sub_style(style : Style, slot : String?) : Style
        case slot
        when "scrollbar" then style.scrollbar
        when "track"     then style.track
        when "cell"      then style.cell
        when "header"    then style.header
        when "item"      then style.item
        when "bar"       then style.bar
        when "prefix"    then style.prefix
        when "alternate" then style.alternate
        when "label"     then style.label
        else                  style
        end
      end

      private def self.set_sub_style(style : Style, slot : String?, sub : Style) : Nil
        case slot
        when "scrollbar" then style.scrollbar = sub
        when "track"     then style.track = sub
        when "cell"      then style.cell = sub
        when "header"    then style.header = sub
        when "item"      then style.item = sub
        when "bar"       then style.bar = sub
        when "prefix"    then style.prefix = sub
        when "alternate" then style.alternate = sub
        when "label"     then style.label = sub
        end
      end
    end
  end
end
