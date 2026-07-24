require "html5"

module Crysterm
  module CSS
    # Resolves a `Stylesheet` against a live widget tree and writes the computed
    # `Style`/`Styles` back onto each widget.
    #
    # The flow, per `#apply`:
    #
    # 1. Render the tree to the CSS document (`Window#to_html`) and parse it.
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
      TIER_DEFAULT = 0 # default/UA stylesheet (base *and* state rules)
      TIER_AUTHOR  = 1 # normal author rules (base)
      TIER_INLINE  = 2 # inline `@style`
      # An author-origin *state* rule (`:hover`/`:selected`/…) or `selection-*`
      # sorts here, above the inline base style — a themed highlight must show
      # even on a widget given an inline base `background`/`color`. (A
      # default/UA-origin state rule stays at `TIER_DEFAULT`, so an author
      # *base* rule still overrides it.)
      TIER_AUTHOR_STATE = 3
      TIER_IMPORTANT    = 4 # `!important` declarations

      # An accumulated match: `{tier, layer_rank, specificity, order,
      # declarations}`, sorted by the first four (origin/importance, then
      # `@layer`, then specificity, then source order) so the winning
      # declaration applies last.
      alias Entry = Tuple(Int32, Int32, Tuple(Int32, Int32, Int32), Int32, Hash(String, String))

      # Resolves the author *stylesheet* (plus the default stylesheet beneath it)
      # against the tree rooted at *window*, matching against the prebuilt CSS
      # document *doc*.
      def self.apply(stylesheet : Stylesheet, window : Window, doc : HTML5::Node, scope : Set(Widget)? = nil) : Nil
        apply_sheets([{CSS.default_stylesheet, TIER_DEFAULT}, {stylesheet, TIER_AUTHOR}], window, doc, scope)
      end

      # Resolves a list of `{stylesheet, base_tier}` sources, lowest tier first,
      # against *window*, matching against the pre-parsed *doc* (the window owns
      # parsing and caches it). Higher tiers win regardless of specificity. When
      # *scope* is given, only widgets in that set have their styles recomputed
      # (incremental update); selector matching is still over the whole document
      # so ancestor/sibling context is correct.
      #
      # Deliberately one flat resolver walk (the benchmarked cascade hot path);
      # splitting it to satisfy the metric would spread cascade state across
      # helpers.
      def self.apply_sheets(sheets : Array(Tuple(Stylesheet, Int32)), window : Window, doc : HTML5::Node, scope : Set(Widget)? = nil) : Nil
        return if sheets.all?(&.[0].rules.empty?)

        # Reuse the window's structurally-cached widget index instead of
        # re-walking the whole tree (and re-interning `uid::slot` strings) every
        # cascade; `index_tree` rebuilds it only on a structural change.
        index = window.css_widget_index { index_tree(window) }

        # Match each distinct structural selector at most once per cascade (the
        # same selector can recur across tiers, states and `@media` blocks).
        selector_cache = Hash(String, Array(HTML5::Node)).new

        # Backward/only structural pseudo-classes (`:last-child`, ...) must count
        # only real child widgets, but the document trails each widget's real
        # children with sub-element/extra pseudo-nodes. When such nodes exist,
        # match those rules against a *structural* document (built lazily, once)
        # that omits the pseudo-nodes; slot nodes still match against the full
        # document.
        has_slots = index.any? { |key, _| key.includes?("::") }
        structural_doc : HTML5::Node? = nil
        structural_cache = Hash(String, Array(HTML5::Node)).new
        # `data-uid -> structural node`, for the slot-subject split's host
        # lookups. Built lazily, only on cascades where such a rule fires.
        structural_hosts : Hash(String, HTML5::Node)? = nil

        # Terminal metrics for `@media` evaluation.
        media_width = window.width
        media_height = window.height
        media_colors = begin
          window.color_count.to_i32
        rescue
          0x1000000
        end
        media_glyphs = window.glyph_tier.value.to_i32

        # Variables merge across sheets in order, so a later (higher-priority)
        # sheet's custom properties win.
        variables = {} of String => String
        sheets.each { |entry| variables.merge!(entry[0].variables) }
        # `variables` is fixed for the whole cascade, so each distinct property
        # *value* resolves to the same string every time; memoizing keeps the
        # theme's handful of `var(--surface)`-style values from being re-resolved
        # thousands of times.
        resolved = {} of String => String

        # Match each rule against the document exactly once: state is carried on
        # the rules, not the nodes, so no need to re-run a selector per state.
        # Base rules (no state pseudo) are collected separately from
        # state-specific rules so they fold into only the states actually needed.
        base = Hash(String, Array(Entry)).new                    # key -> base entries
        acc = Hash(Tuple(String, WidgetState), Array(Entry)).new # {key, state} -> state entries
        stated_keys = Hash(String, Set(WidgetState)).new         # key -> states with own rules
        # `selection-color`/`selection-background-color` declarations, rewritten to
        # `color`/`background-color` and destined for the `:selected` state (Qt's
        # selection colors are a state-independent appearance, like geometry).
        sel_acc = Hash(String, Array(Entry)).new # key -> selected-state entries

        sheets.each do |(sheet, tier)|
          sheet.rules.each do |rule|
            next if rule.selector.empty?
            if mq = rule.media
              next unless mq.matches?(media_width, media_height, media_colors, media_glyphs)
            end
            if has_slots && backward_structural?(rule.selector)
              # Real child widgets *and* extra pseudo-nodes (table `Row`/`Cell`,
              # which carry a `:` in their slot key) are matched against the
              # sub-element-free structural document, so their backward/only
              # structural pseudos count only real siblings and rows — not the
              # trailing scrollbar/track/label nodes. Only the *sub-element*
              # pseudo-nodes (`::scrollbar`/`::track`/`::label`, no `:` in the
              # slot) still come from the full document, where alone they exist.
              # Cached on the `Window` across cascades; the `||=` memoizes within
              # this cascade so the string isn't re-serialized per rule.
              sdoc = structural_doc ||= window.css_structural_document
              real = matched_nodes(sheet, sdoc, rule, structural_cache)
              # A slot-subject rule (`Box:last-child::scrollbar`, lowered to
              # `.Box:last-child .Scrollbar`) can't run wholesale against
              # either document: the slot node exists only in the full one,
              # where the prefix's backward pseudo miscounts (and the engine
              # can't even compile some shapes, e.g. a child combinator
              # followed by a descendant one). Split it — prefix against the
              # structural document, slot compound against the full one,
              # joined by host uid. Non-slot subjects fall back to the plain
              # full-document match.
              slots =
                if split = split_slot_selector(rule.selector)
                  hosts = structural_hosts ||= uid_node_index(sdoc)
                  slot_subject_nodes(sheet, doc, sdoc, rule, split, selector_cache, structural_cache, hosts)
                else
                  matched_nodes(sheet, doc, rule, selector_cache).select { |node| sub_element_uid?(node) }
                end
              nodes = real + slots
            else
              nodes = matched_nodes(sheet, doc, rule, selector_cache)
            end
            # A state pseudo-class rule (`:hover`/`:selected`/`:focus`/…) is more
            # specific than the state-agnostic inline `@style`: a themed
            # selection/hover highlight must show even over an inline base
            # `background`/`color`. So an *author* state rule's normal
            # declarations sort at `TIER_AUTHOR_STATE`, while default/UA state
            # rules (and any base rule) stay at their sheet tier. `!important`
            # still outranks all.
            entries = rule_entries(rule, rule.state ? state_tier(tier) : tier)
            sel_entries = selection_entries(rule, tier)
            next if entries.empty? && sel_entries.empty?
            nodes.each do |node|
              key = node["data-uid"]?.try(&.val)
              next unless key
              unless entries.empty?
                if state = rule.state
                  (acc[{key, state}] ||= [] of Entry).concat entries
                  (stated_keys[key] ||= Set(WidgetState).new) << state
                  # A state rule on a sub-element (`uid::slot:hover`) marks only
                  # the slot key stated, yet `touched` derives the parent uid and
                  # materializes the parent's Hovered style. Unless the parent is
                  # also marked stated, the base fold never reaches that state and
                  # the widget flashes unstyled while hovered/focused.
                  mark_parent_stated stated_keys, key, state
                else
                  (base[key] ||= [] of Entry).concat entries
                end
              end
              # `selection-*` always feeds the selected state regardless of the
              # rule's own state pseudo. Mark it stated so the base rule folds
              # into it too (selected = base + selection overrides).
              unless sel_entries.empty?
                (sel_acc[key] ||= [] of Entry).concat sel_entries
                (stated_keys[key] ||= Set(WidgetState).new) << WidgetState::Selected
                mark_parent_stated stated_keys, key, WidgetState::Selected
              end
            end
          end
        end

        # Fold base entries into `normal` plus any state that has its own rules
        # for that key (so e.g. a focused style is `base + :focus`). States with
        # no rules fall back to `normal` lazily at render time.
        base.each do |key, entries|
          own = stated_keys[key]?
          # Fast path for the common widget-key with base rules, no state rules
          # and no "::" (so no parent-state fold either): fold straight into
          # Normal without allocating a throwaway one-element Set.
          if own.nil? && !key.includes?("::")
            (acc[{key, WidgetState::Normal}] ||= [] of Entry).concat entries
            next
          end
          states = own.try(&.dup) || Set(WidgetState).new
          states << WidgetState::Normal
          # A sub-element key (`uid::slot`) lives inside the parent widget's
          # per-state styles, so it must also fold into every state the parent is
          # materialized in — otherwise a widget given an explicit state (a
          # focused `Input` via `Input:focus`) materializes that state with a
          # pristine sub-element, dropping a base `ProgressBar::indicator` rule
          # on the focused bar alone. Extra (`:`-bearing) slots are
          # state-independent, so skip them.
          if (sep = key.index("::")) && !key[(sep + 2)..].includes?(':')
            stated_keys[key[0, sep]]?.try { |ps| states.concat ps }
          end
          states.each { |state| (acc[{key, state}] ||= [] of Entry).concat entries }
        end

        # Fold the rewritten `selection-*` entries onto the selected state, after
        # the base fold so they sort after (and override) the base
        # `color`/`background-color` on an equal-specificity tie.
        sel_acc.each do |key, entries|
          (acc[{key, WidgetState::Selected}] ||= [] of Entry).concat entries
        end

        touched = Set(Tuple(String, WidgetState)).new
        acc.each_key { |(key, state)| touched << {key.partition("::")[0], state} }

        # Reset every recomputed widget to its pristine pre-CSS styles before
        # (re)applying rules. This is what makes the cascade non-stale: a widget
        # that stopped matching a rule, or whose inherited value changed, starts
        # clean rather than building on its previous computed styles.
        # (Inherited-into widgets aren't `css_styled`, so every candidate is
        # reset, not just matched ones.)
        each_recompute_candidate(index, scope) do |widget|
          widget.styles = widget.css_base_styles.deep_dup
          widget.css_styled = false
          widget.css_reset_extra
          # The reset wiped any sub-control style an ancestor pushed onto this
          # widget, but the ancestor's own sub-`Style` object survives when it's
          # outside the scope — so the push memo would keep reporting `same?` and
          # skip re-pushing forever. Drop it so the next push re-dups.
          widget._substyle_src = nil
          # Geometry has the same non-staleness contract as styles, but lives on
          # the widget itself: restore the pristine snapshot so a geometry rule
          # that stopped matching reverts rather than sticking. The
          # currently-matching declarations re-apply below.
          widget.restore_css_base_geometry

          # Fold the full inline `@style` onto `normal`, the fallback state every
          # unset state defers to. The per-state inline fold below only runs for
          # states a rule actually touches, so a widget themed only for, say,
          # `:selected` would otherwise have its inline `border`/`bg` folded into
          # that state alone while `normal` reverted to pristine. Touched states
          # are reset to pristine again below and re-fold inline at the correct
          # tier, so this never double-applies.
          if inl = widget.inline_style
            fold_inline widget.styles.normal, inl
          end
        end

        # Give every touched (widget, state) its own `Style` up front (fresh
        # pristine dup). A state that otherwise falls back to `normal` would, if
        # mutated in place by a sub-element rule, leak into `normal`.
        touched.each do |(uid, state)|
          if target = index[uid]?
            next unless scope.nil? || scope.includes?(target[0])
            set_state_style target[0], state, base_state_style(target[0], state)
          end
        end

        # Apply each touched widget's main style: author/default declarations,
        # then inline `@style` (tier 2), then `!important` (tier 3). Every
        # touched widget is processed (even one matched only via a sub-element)
        # so its inline style still folds in, and is marked `css_styled` so
        # `#style` returns the computed result. Out-of-scope widgets keep their
        # already-computed styles (incremental update).
        touched.each do |(uid, state)|
          next unless target = index[uid]?
          widget = target[0]
          next unless scope.nil? || scope.includes?(widget)
          entries = acc[{uid, state}]? || EMPTY_ENTRIES
          apply_entries_with_inline get_state_style(widget, state), entries, variables, resolved, widget.inline_style
          # Geometry/layout is per-widget, not per-state: apply once from the
          # (now sorted) normal-state entries.
          apply_geometry widget, entries, variables, resolved if state.normal?
          widget.css_styled = true
        end

        # Sub-element styles build on the now-current per-state style. Extra
        # slots (those with a `:` — e.g. a table cell `cell:0:1`) are routed to
        # the widget's own per-slot storage instead of a `Style` sub-style.
        #
        # A whole-row extra slot (`::row:N`, `Row { ... }`) fans its computed
        # style out onto the row's cells, establishing the per-cell base a
        # `Cell`/`Cell:nth-child(...)` rule then layers on top. So row slots must
        # be applied *before* cell slots; `acc` is an unordered hash, hence the
        # sort (order among cells, or among rows, is immaterial).
        # Collect only the sub-element (`::`) keys directly instead of `to_a`-ing
        # the whole accumulation hash (one entry per touched widget/state) and
        # discarding the majority. The `::row:`-presence test the sort needs is
        # folded into the same single pass.
        subs = [] of Tuple(Tuple(String, WidgetState), Array(Entry))
        has_row = false
        acc.each do |key_tuple, entries|
          next unless key_tuple[0].includes?("::")
          subs << {key_tuple, entries}
          has_row = true if key_tuple[0].includes?("::row:")
        end
        subs.sort_by! { |((key, _state), _entries)| key.includes?("::row:") ? 0 : 1 } if has_row
        subs.each do |(key, state), entries|
          next unless target = index[key]?
          widget, slot = target
          next unless slot
          next unless scope.nil? || scope.includes?(widget)
          if slot.includes?(':')
            # Extra slots (a table cell `cell:0:1`) have state-*independent*
            # storage — one `Style` per cell — but `acc` is keyed per-{key,
            # state}, so processing every state would race last-write-wins. Only
            # the Normal (base) entries apply; state-specific ones are dropped,
            # since the slot can't represent them.
            next unless state.normal?
            base = widget.css_extra_base_style(slot).dup
            apply_entries base, entries, variables, resolved
            widget.css_set_extra_style(slot, base)
          else
            state_style = get_state_style(widget, state)
            sub = state_style.sub_style(slot).dup
            # Inline sub-styles outrank default/author sub-element rules, the
            # same inline-beats-stylesheet contract the main style honors.
            # Interleaved at `TIER_INLINE` so `!important` sub-element rules
            # still win over it.
            inline_sub = widget.inline_style.try &.raw_sub_style(slot)
            apply_entries_with_inline sub, entries, variables, resolved, inline_sub
            state_style.set_sub_style slot, sub
          end
        end

        inherit window
      end

      EMPTY_ENTRIES = [] of Entry

      # `WidgetState.values` minus `Normal`, hoisted once so the per-widget
      # inheritance tree-walk (`inherit_into`) doesn't heap-allocate a fresh
      # Array(WidgetState) on every non-root widget every cascade.
      private NON_NORMAL_STATES = WidgetState.values.reject(&.normal?)

      # Whether *node* has a descendant (or, with `:scope`, relative element)
      # matching the `:has(...)` inner selector.
      private def self.has_descendant?(node : HTML5::Node, inner : String) : Bool
        !node.css(inner).empty?
      rescue
        false
      end

      # Runs *selector* (compiled by and cached on *sheet*, reused across
      # cascades) against this cascade's *doc*. An unparseable selector compiles
      # to `nil` and matches nothing; a raising select also yields nothing.
      private def self.select_nodes(sheet : Stylesheet, doc : HTML5::Node, selector : String) : Array(HTML5::Node)
        if compiled = sheet.compiled_selector(selector)
          begin
            compiled.select(doc)
          rescue
            [] of HTML5::Node
          end
        else
          [] of HTML5::Node
        end
      end

      # Selectors bearing a backward/only structural pseudo-class, whose sibling
      # counting must exclude the trailing sub-element/extra pseudo-nodes.
      # `:nth-last-` covers both `:nth-last-child` and `:nth-last-of-type`.
      BACKWARD_STRUCTURAL = /:(?:last-child|only-child|last-of-type|only-of-type|nth-last-)/

      private def self.backward_structural?(selector : String) : Bool
        selector.matches?(BACKWARD_STRUCTURAL)
      end

      # Nodes matching *rule* against *doc*: the compiled selector's matches,
      # then the relational `:has`/ancestor-`:has` post-filters (the engine has
      # no native `:has`). *cache* memoizes selector results for *doc*; pass a
      # per-document cache so full- and structural-document results don't collide.
      private def self.matched_nodes(sheet : Stylesheet, doc : HTML5::Node, rule : Rule, cache : Hash(String, Array(HTML5::Node))) : Array(HTML5::Node)
        nodes = cache.fetch(rule.selector) do
          cache[rule.selector] = select_nodes(sheet, doc, rule.selector)
        end
        # `:has(...)` — keep only nodes with a descendant matching the inner
        # selector.
        if has = rule.has
          nodes = nodes.select { |node| has_descendant?(node, has) }
        end
        # Ancestor-position `:has(...)` (`Form:has(.error) Button`): the
        # structural selector already pins the subject under the qualifier
        # compound; additionally require a matching ancestor satisfying the
        # relational `:has` (has an `inner` descendant). All conditions AND.
        if anc = rule.ancestor_has
          anc.each do |(qualifier, inner)|
            qualified = qualified_ancestors(sheet, doc, qualifier, inner, cache)
            nodes = qualified.empty? ? [] of HTML5::Node : nodes.select { |node| descends_from?(node, qualified) }
          end
        end
        nodes
      end

      # Whether *node* is a sub-element pseudo-node — a `uid::slot` `data-uid`
      # whose slot part carries no further `:` (extra slots like a table's
      # `row:0`/`cell:0:1` match structurally, not here).
      private def self.sub_element_uid?(node : HTML5::Node) : Bool
        return false unless k = node["data-uid"]?
        sep = k.val.index("::")
        sep ? !k.val[(sep + 2)..].includes?(':') : false
      end

      # The subject compound `lower_sub_elements` emits for a `::slot`: a single
      # capitalized class, optionally with attribute selectors.
      SLOT_COMPOUND = /\A\.[A-Z][a-zA-Z0-9_-]*(?:\[[^\]]*\])*\z/

      # Splits a rule selector whose subject is a slot compound into `{prefix,
      # combinator, compound}` at the last top-level combinator (quote- and
      # bracket-aware). Returns nil — caller falls back to the plain
      # full-document match — when the subject isn't a slot compound, the final
      # combinator is a sibling one, or there is no prefix at all.
      private def self.split_slot_selector(selector : String) : Tuple(String, Char, String)?
        n = selector.size
        i = 0
        comb = ' '
        prefix_end = -1
        subject_start = -1
        while i < n
          case selector[i]
          when '"', '\''
            i = Selectors.skip_string(selector, i)
          when '['
            i = Selectors.skip_balanced(selector, i, '[', ']')
          when '('
            i = Selectors.skip_balanced(selector, i, '(', ')')
          when ' ', '>', '+', '~'
            prefix_end = i
            comb = ' '
            while i < n && ((c = selector[i]) == ' ' || c == '>' || c == '+' || c == '~')
              comb = c unless c == ' '
              i += 1
            end
            subject_start = i
          else
            i += 1
          end
        end
        return if subject_start <= 0 || subject_start >= n
        return unless comb == ' ' || comb == '>'
        compound = selector[subject_start..]
        return unless compound.matches?(SLOT_COMPOUND)
        prefix = selector[0, prefix_end].strip
        return if prefix.empty?
        {prefix, comb, compound}
      end

      # Matches a backward-structural slot-subject rule via its *split*: the
      # prefix runs against the structural document *sdoc* (correct sibling
      # counts), the slot compound against the full *doc* (where alone slot
      # nodes exist), and a candidate survives when its host widget — the
      # structural node for the `data-uid` text before `::` — is a prefix match
      # (child combinator) or is-or-descends-from one (descendant combinator:
      # the `::slot` lowering inserts a descendant combinator, so
      # `List:last-child Scrollbar` also reaches scrollbars nested under the
      # matched ancestor, as the plain full-document path provides). The rule's
      # relational `:has` filters then apply, as in `matched_nodes`.
      private def self.slot_subject_nodes(sheet : Stylesheet, doc : HTML5::Node, sdoc : HTML5::Node, rule : Rule, split : Tuple(String, Char, String), cache : Hash(String, Array(HTML5::Node)), structural_cache : Hash(String, Array(HTML5::Node)), hosts : Hash(String, HTML5::Node)) : Array(HTML5::Node)
        prefix, comb, compound = split
        matched = structural_cache.fetch(prefix) do
          structural_cache[prefix] = select_nodes(sheet, sdoc, prefix)
        end
        return [] of HTML5::Node if matched.empty?
        prefix_set = matched.to_set
        candidates = cache.fetch(compound) do
          cache[compound] = select_nodes(sheet, doc, compound)
        end
        nodes = candidates.select do |node|
          next false unless key = node["data-uid"]?.try(&.val)
          next false unless sep = key.index("::")
          next false if key[(sep + 2)..].includes?(':')
          next false unless host = hosts[key[0, sep]]?
          prefix_set.includes?(host) || (comb == ' ' && descends_from?(host, prefix_set))
        end
        if has = rule.has
          nodes.select! { |node| has_descendant?(node, has) }
        end
        if anc = rule.ancestor_has
          anc.each do |(qualifier, inner)|
            qualified = qualified_ancestors(sheet, doc, qualifier, inner, cache)
            nodes = qualified.empty? ? [] of HTML5::Node : nodes.select { |node| descends_from?(node, qualified) }
          end
        end
        nodes
      end

      # `data-uid -> node` over the structural document, for the slot-subject
      # split's host lookups. Iterative walk (hot-path convention).
      private def self.uid_node_index(doc : HTML5::Node) : Hash(String, HTML5::Node)
        index = {} of String => HTML5::Node
        stack = [doc]
        while node = stack.pop?
          node["data-uid"]?.try { |attr| index[attr.val] = node }
          child = node.first_child
          while child
            stack << child
            child = child.next_sibling
          end
        end
        index
      end

      # The set of nodes matching *qualifier* (an ancestor compound) that satisfy
      # its relational `:has(inner)`. The bare *qualifier* match is cached in
      # *cache* alongside the rule selectors.
      private def self.qualified_ancestors(sheet : Stylesheet, doc : HTML5::Node, qualifier : String, inner : String, cache : Hash(String, Array(HTML5::Node))) : Set(HTML5::Node)
        base = cache.fetch(qualifier) do
          cache[qualifier] = select_nodes(sheet, doc, qualifier)
        end
        set = Set(HTML5::Node).new
        base.each { |n| set << n if has_descendant?(n, inner) }
        set
      end

      # Whether *node* is a descendant of any node in *ancestors* (walking the
      # parent chain; `Set(HTML5::Node)` uses reference identity).
      private def self.descends_from?(node : HTML5::Node, ancestors : Set(HTML5::Node)) : Bool
        cur = node.parent
        while cur
          return true if ancestors.includes?(cur)
          cur = cur.parent
        end
        false
      end

      # `selection-*` property -> the standard property it maps to on the
      # selected state.
      SELECTION_PROPS = {
        "selection-color"            => "color",
        "selection-background-color" => "background-color",
      }

      # Added to a selection entry's source order so it sorts after — and thus
      # wins an equal-specificity tie against — the base `color`/`background-color`
      # folded onto the selected state. Larger than any real stylesheet's rule
      # count, so it only breaks ties, never reorders different specificities (a
      # higher-specificity explicit `:selected` rule still wins).
      SELECTION_ORDER_BIAS = 1_000_000

      # The selected-state entries a rule contributes via its `selection-*`
      # declarations (rewritten to `color`/`background-color`), or an empty array
      # when it has none.
      private def self.selection_entries(rule : Rule, base_tier : Int32) : Array(Entry)
        # Cheap membership test first: most rules have no `selection-*`, so skip
        # without allocating a remap hash.
        has_normal = has_selection?(rule.declarations)
        has_important = has_selection?(rule.important)
        return EMPTY_ENTRIES unless has_normal || has_important
        order = rule.order + SELECTION_ORDER_BIAS
        entries = [] of Entry
        # `selection-*` styles the selected state, so — like a `:selected` rule —
        # an author-origin one sorts at `TIER_AUTHOR_STATE` (a default-origin one
        # stays at its sheet tier).
        entries << {state_tier(base_tier), rule.layer_rank, rule.specificity, order, remap_selection(rule.declarations)} if has_normal
        entries << {TIER_IMPORTANT, rule.layer_rank, rule.specificity, order, remap_selection(rule.important)} if has_important
        entries
      end

      # Whether *decls* carries any `selection-*` property.
      private def self.has_selection?(decls : Hash(String, String)) : Bool
        SELECTION_PROPS.each_key { |k| return true if decls.has_key?(k) }
        false
      end

      # Picks out the `selection-*` declarations from *decls*, keyed by the
      # standard property they map to. Only called once presence is confirmed,
      # so it never returns empty.
      private def self.remap_selection(decls : Hash(String, String)) : Hash(String, String)
        out = {} of String => String
        SELECTION_PROPS.each { |from, to| decls[from]?.try { |v| out[to] = v } }
        out
      end

      # The tier for a state/selection rule's *normal* declarations: an author
      # rule is lifted above the inline `@style` (`TIER_AUTHOR_STATE`) so a themed
      # highlight shows over an inline base color; a default/UA rule keeps its
      # sheet tier (so an author base rule still overrides it).
      private def self.state_tier(base_tier : Int32) : Int32
        base_tier == TIER_AUTHOR ? TIER_AUTHOR_STATE : base_tier
      end

      # When a state rule lands on a sub-element key (`uid::slot`), records the
      # same state under the *parent* uid so the parent's base rules fold into
      # that state's materialized style. A no-op for a top-level (`::`-free) key.
      private def self.mark_parent_stated(stated_keys : Hash(String, Set(WidgetState)), key : String, state : WidgetState) : Nil
        if sep = key.index("::")
          (stated_keys[key[0, sep]] ||= Set(WidgetState).new) << state
        end
      end

      # The cascade entries a rule contributes: its normal declarations at
      # *base_tier*, and its `!important` declarations at `TIER_IMPORTANT`.
      private def self.rule_entries(rule : Rule, base_tier : Int32) : Array(Entry)
        entries = [] of Entry
        entries << {base_tier, rule.layer_rank, rule.specificity, rule.order, rule.declarations} unless rule.declarations.empty?
        entries << {TIER_IMPORTANT, rule.layer_rank, rule.specificity, rule.order, rule.important} unless rule.important.empty?
        entries
      end

      # Sort key: `{tier, layer_rank, specificity, order}`, ascending — the
      # winning declaration sorts last.
      #
      # `!important` *reverses* layer priority, per the CSS cascade: an
      # earlier-declared `@layer` beats a later one among important
      # declarations, and an unlayered important declaration is weakest of all
      # — the opposite of normal declarations. Negating `layer_rank` for the
      # important tier flips the otherwise-ascending order to match.
      private def self.entry_key(entry : Entry)
        layer = entry[0] == TIER_IMPORTANT ? -entry[1] : entry[1]
        {entry[0], layer, entry[2], entry[3]}
      end

      # Resolves *value*'s `var(...)` references against *variables*, memoizing
      # in *resolved* (one entry per distinct value, valid for the whole
      # cascade). `var()`-free values cost only a hash lookup.
      private def self.resolve_var(value : String, variables : Hash(String, String), resolved : Hash(String, String)) : String
        resolved.fetch(value) { resolved[value] = Stylesheet.resolve_var(value, variables) }
      end

      # Folds *entries* onto *style* in place, in cascade order (so the winning
      # declaration applies last). `var(...)` is resolved against *variables*.
      private def self.apply_entries(style : Style, entries : Array(Entry), variables : Hash(String, String), resolved : Hash(String, String)) : Nil
        entries.sort_by! { |entry| entry_key entry }
        entries.each { |entry| apply_decls style, entry[4], variables, resolved }
      end

      # Like `apply_entries`, but interleaves the inline `@style` at
      # `TIER_INLINE`: entries below that tier (default + author) apply first,
      # then the inline style, then entries at/above it (`!important`). So inline
      # outranks normal author rules but `!important` outranks inline.
      private def self.apply_entries_with_inline(style : Style, entries : Array(Entry), variables : Hash(String, String), resolved : Hash(String, String), inline : Style?) : Nil
        entries.sort_by! { |entry| entry_key entry }
        i = 0
        while i < entries.size && entries[i][0] < TIER_INLINE
          apply_decls style, entries[i][4], variables, resolved
          i += 1
        end
        fold_inline style, inline if inline
        while i < entries.size
          apply_decls style, entries[i][4], variables, resolved
          i += 1
        end
      end

      private def self.apply_decls(style : Style, declarations : Hash(String, String), variables : Hash(String, String), resolved : Hash(String, String)) : Nil
        declarations.each do |property, value|
          Properties.apply(style, property, resolve_var(value, variables, resolved))
        end
      end

      # Applies geometry/layout declarations (width/height/position/text-align)
      # onto the widget itself, from *entries* in cascade order (last wins).
      # Already sorted by the caller.
      private def self.apply_geometry(widget : Widget, entries : Array(Entry), variables : Hash(String, String), resolved : Hash(String, String)) : Nil
        entries.each do |entry|
          entry[4].each do |property, value|
            next unless Geometry.handles?(property)
            # Snapshot the pristine geometry before CSS first writes it, so the
            # reset pass can revert a rule that stops matching. Memoized.
            widget.capture_css_base_geometry
            Geometry.apply(widget, property, resolve_var(value, variables, resolved))
          end
        end
      end

      # Folds an inline `@style`'s explicitly-set properties onto *style*. Each
      # property is copied only if the inline style `specified?` it — so inline
      # can switch a text attribute either on or off over a stylesheet.
      private def self.fold_inline(style : Style, inline : Style) : Nil
        # `nil`-signalled properties (no `specified_mask` bit) — folded by hand.
        style.fg = inline.fg if inline.specified?(:fg)
        style.bg = inline.bg if inline.specified?(:bg)
        style.opacity = inline.opacity if inline.specified?(:opacity)
        if inline.specified?(:tint)
          style.tint = inline.tint
          style.tint_alpha = inline.tint_alpha
        end
        style.gridline_color = inline.gridline_color if inline.specified?(:gridline_color)
        style.z_index = inline.z_index if inline.specified?(:z_index)
        style.background_image = inline.background_image if inline.specified?(:background_image)
        style.transitions = inline.transitions if inline.specified?(:transitions)
        style.animation = inline.animation if inline.specified?(:animation)
        style.glyph = inline.glyph if inline.specified?(:glyph)
        style.glyph_ascii = inline.glyph_ascii if inline.specified?(:glyph_ascii)
        style.glyph_unicode = inline.glyph_unicode if inline.specified?(:glyph_unicode)
        style.glyph_extended = inline.glyph_extended if inline.specified?(:glyph_extended)
        style.glyph_open = inline.glyph_open if inline.specified?(:glyph_open)
        style.glyph_close = inline.glyph_close if inline.specified?(:glyph_close)
        style.glyphs = inline.glyphs if inline.specified?(:glyphs)
        # Mask-tracked properties (text attributes, border/padding/margin/shadow,
        # fill chars, tabs, fill/draw_over_border). Uses `specified?` (not
        # `any?`), so inline can switch border/padding/margin/shadow off over a
        # stylesheet, not only on.
        inline.fold_specified_onto style
        # Nested sub-styles (header/cell/alternate/bar/…) copy wholesale;
        # otherwise the reset-and-recompute drops them, since no `Widget::slot`
        # sub-element rule restores an inline-only sub-style.
        style.fold_inline_sub_styles inline
      end

      # Yields each widget eligible to be reset/recomputed: every (main) widget
      # in the document index (`slot.nil?`), intersected with *scope* when
      # scoped. Filtering against the index guarantees the cascade only touches
      # *this* window's widgets — a `scope` could otherwise include a widget
      # that has since moved to another window (a stale dirty-subtree root).
      private def self.each_recompute_candidate(index, scope : Set(Widget)?, & : Widget ->) : Nil
        index.each_value do |(widget, slot)|
          next unless slot.nil?
          next unless scope.nil? || scope.includes?(widget)
          yield widget
        end
      end

      # Walks the widget tree, mapping each `data-uid` key (and each sub-element
      # `uid::slot` key) back to its `{widget, slot}`.
      private def self.index_tree(window : Window) : Hash(String, Tuple(Widget, String?))
        index = {} of String => Tuple(Widget, String?)
        window.children.each { |child| index_widget child, index }
        index
      end

      private def self.index_widget(widget : Widget, index) : Nil
        uid = widget.uid_s
        index[uid] = {widget, nil}
        widget.css_sub_elements.each do |slot|
          index["#{uid}::#{slot}"] = {widget, slot}
        end
        widget.css_extra_slots.each do |slot|
          index["#{uid}::#{slot}"] = {widget, slot}
        end
        widget.children.each { |child| index_widget child, index }
      end

      # Inherits the classically-inherited properties — `color` (fg),
      # `font-weight` (bold) and `font-style` (italic) — down the tree wherever a
      # widget's normal style leaves them unset. Runs pre-order so a parent's
      # resolved value is available to children, and re-propagates to grandchildren.
      #
      # Visibility is deliberately *not* inherited: a hidden parent already keeps
      # children off-window via its own `base_render`, so propagating `visible:
      # false` is redundant and goes stale — when the parent is re-shown, nothing
      # re-cascades the child, leaving it stuck invisible. Each widget owns its
      # visibility outright.
      private def self.inherit(window : Window) : Nil
        window.children.each { |child| inherit_into child, nil }
      end

      private def self.inherit_into(widget : Widget, parent : Style?) : Nil
        normal = widget.styles.normal
        if parent
          inherit_props normal, parent
          # An inherited value is stateless: it must reach every materialized
          # state, exactly as a stateless `color`/`font-*` rule does. Seeding
          # only `normal` would lose it whenever the widget enters a state with
          # its own rule — a field with a bg-only `:focus` rule would render
          # focused text in the terminal default fg. A lazily-falling-back state
          # shares the `normal` object, so `same?` skips it: it already sees the
          # value via `normal`.
          NON_NORMAL_STATES.each do |state|
            st = widget.styles[state]
            inherit_props st, parent unless st.same?(normal)
          end
        end
        widget.children.each { |child| inherit_into child, normal }
      end

      # Copies the classically-inherited properties from *parent* onto *style*
      # wherever *style* leaves them unset (so an explicit value always wins).
      private def self.inherit_props(style : Style, parent : Style) : Nil
        style.fg = parent.fg if !style.specified?(:fg) && parent.specified?(:fg)
        style.bold = parent.bold? if !style.specified?(:bold) && parent.specified?(:bold)
        style.italic = parent.italic? if !style.specified?(:italic) && parent.specified?(:italic)
      end

      # --- per-state style accessors -----------------------------------------

      # A fresh dup of the widget's pristine (pre-CSS) style for *state* — the
      # clean base declarations get applied onto.
      private def self.base_state_style(widget : Widget, state : WidgetState) : Style
        widget.css_base_styles[state].dup
      end

      private def self.get_state_style(widget : Widget, state : WidgetState) : Style
        widget.styles[state]
      end

      private def self.set_state_style(widget : Widget, state : WidgetState, style : Style) : Nil
        widget.styles[state] = style
      end
    end
  end
end
