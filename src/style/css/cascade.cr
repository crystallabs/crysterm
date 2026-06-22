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
    #    keyed by widget/slot/state and tagged with specificity and source order.
    #    A base rule is folded into `normal` plus only those states that have a
    #    state-specific rule; the rest lazily fall back to `normal`.
    # 4. Fold each accumulation (sorted by specificity then order) onto a copy of
    #    the widget's existing style for that state — so CSS overrides only the
    #    properties it specifies and leaves widget defaults intact.
    # 5. Inherit the (inheritable) `color` down the tree where unset.
    #
    # Application is non-destructive and opt-in: only widget/state pairs that a
    # rule actually matched are touched, and the inline `@style` override still
    # wins at render time.
    module Cascade
      # An accumulated match: specificity, source order, and the declarations to
      # apply. Sorted by `{specificity, order}` so later/again-more-specific
      # rules win.
      alias Entry = Tuple(Tuple(Int32, Int32, Int32), Int32, Hash(String, String))

      # Resolves *stylesheet* against the tree rooted at *screen*.
      def self.apply(stylesheet : Stylesheet, screen : Screen) : Nil
        return if stylesheet.rules.empty?

        doc = HTML5.parse(screen.to_html)
        index = index_tree(screen)

        # Match each rule against the document exactly once: the document is the
        # same in every state (state is carried on the rules, not the nodes), so
        # there is no need to re-run a selector per state. Base rules (no state
        # pseudo) are collected separately from state-specific rules so they can
        # be folded into only the states that are actually needed.
        base = Hash(String, Array(Entry)).new                    # key -> base entries
        acc = Hash(Tuple(String, WidgetState), Array(Entry)).new # {key, state} -> state entries
        stated_keys = Hash(String, Set(WidgetState)).new         # key -> states with own rules

        stylesheet.rules.each do |rule|
          next if rule.selector.empty?
          nodes = begin
            doc.css(rule.selector)
          rescue
            next # ignore selectors the engine can't parse
          end
          entry = {rule.specificity, rule.order, rule.declarations}
          nodes.each do |node|
            key = node["data-uid"]?.try(&.val)
            next unless key
            if state = rule.state
              (acc[{key, state}] ||= [] of Entry) << entry
              (stated_keys[key] ||= Set(WidgetState).new) << state
            else
              (base[key] ||= [] of Entry) << entry
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

        # Give every touched (widget, state) its own `Style` up front. A state
        # whose style otherwise lazily falls back to `normal` would, if mutated
        # in place by a sub-element rule, leak into `normal`; an owned copy
        # prevents that.
        touched = Set(Tuple(String, WidgetState)).new
        acc.each_key { |(key, state)| touched << {key.partition("::")[0], state} }
        touched.each do |(uid, state)|
          if target = index[uid]?
            set_state_style target[0], state, get_state_style(target[0], state).dup
          end
        end

        # Apply main-element styles first (in place, onto the owned copy from the
        # materialize step above), then sub-element styles (which build on the
        # now-current per-state style).
        acc.each do |(key, state), entries|
          next if key.includes?("::")
          next unless target = index[key]?
          apply_entries get_state_style(target[0], state), entries
        end

        acc.each do |(key, state), entries|
          next unless key.includes?("::")
          next unless target = index[key]?
          widget, slot = target
          state_style = get_state_style(widget, state)
          sub = get_sub_style(state_style, slot).dup
          apply_entries sub, entries
          set_sub_style state_style, slot, sub
        end

        inherit_color screen
      end

      # Folds *entries* onto *style* in place, in cascade order (specificity then
      # source order, so the last/most-specific declaration wins).
      private def self.apply_entries(style : Style, entries : Array(Entry)) : Nil
        entries.sort_by! { |entry| {entry[0], entry[1]} }
        entries.each do |entry|
          entry[2].each { |property, value| Properties.apply(style, property, value) }
        end
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

      # Inherits `color` (fg) down the tree where a widget's normal style leaves
      # it unset — the one classically inheritable property. Runs pre-order so a
      # parent's resolved color is available to its children.
      private def self.inherit_color(screen : Screen) : Nil
        screen.children.each { |child| inherit_color_into child, nil }
      end

      private def self.inherit_color_into(widget : Widget, parent_fg : Int32?) : Nil
        normal = widget.styles.normal
        normal.fg = parent_fg if normal.fg.nil? && parent_fg
        effective = normal.fg || parent_fg
        widget.children.each { |child| inherit_color_into child, effective }
      end

      # --- per-state style accessors -----------------------------------------

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
        end
      end
    end
  end
end
