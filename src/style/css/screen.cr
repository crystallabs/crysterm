module Crysterm
  class Window
    # The stylesheet driving CSS styling for this screen, if any. Assigning one
    # (as text or a parsed `CSS::Stylesheet`) marks styling dirty; the cascade
    # runs on the next render. With no stylesheet set, nothing changes and
    # widgets keep their programmatic styles.
    def stylesheet : CSS::Stylesheet?
      @css_stylesheet
    end

    # Whether styling needs recomputing on the next render.
    getter? css_dirty = false

    # Whether the next recompute must cover the whole tree (vs. only the dirty
    # subtrees in `@css_dirty_roots`). Set by stylesheet changes and by
    # top-level changes that can't be scoped.
    @css_full = false

    # Subtree roots to recompute on the next (scoped) cascade. Each entry's whole
    # subtree is recomputed; everything else keeps its already-computed styles.
    @css_dirty_roots = Set(Widget).new

    # The screen is the styling root, so a structural change on it can't be
    # scoped to a subtree — recompute everything.
    protected def invalidate_css : Nil
      restyle
    end

    # A top-level structural change forces a document re-parse and full
    # recompute.
    protected def invalidate_css_tree : Nil
      @css_structural = true
      restyle
    end

    # Path the active stylesheet was loaded from, for `#reload_stylesheet` /
    # `#watch_stylesheet`.
    def stylesheet_path : String?
      @css_stylesheet_path
    end

    # Caches the last CSS document the cascade ran against, so an
    # `#apply_stylesheet` whose document is byte-identical is skipped. Reset
    # whenever the stylesheet itself changes (the document doesn't encode rules).
    @css_last_document : String?

    # Terminal `{width, height}` at the last cascade. Lets `#apply_stylesheet_if_dirty`
    # notice a resize and re-run a media-guarded cascade even though nothing marked
    # styling dirty (the resize path doesn't). `nil` until the first cascade.
    @css_last_size : Tuple(Int32, Int32)?

    # Glyph tier at the last cascade — the `@media (glyphs: …)` analog of
    # `@css_last_size`: a `glyph_tier = …` switch marks nothing dirty, so a
    # media-guarded cascade re-runs when the tier changed since. `nil` until the
    # first cascade.
    @css_last_glyph_tier : Glyphs::Tier?

    # `CSS.default_stylesheet_generation` at the last `#apply_stylesheet` run,
    # so a runtime theme / default-sheet swap (which marks nothing dirty on any
    # window) forces a full recompute. `nil` until the first run.
    @css_last_default_generation : Int32?

    # Whether a cascade has styled this window's widgets (and no reset has
    # reverted them since). Gates the revert-to-pristine pass in
    # `#apply_stylesheet`'s no-active-rules branch, so a window that was never
    # styled doesn't walk its tree on every render while unstyled.
    # `@css_last_document` can't serve as this marker: the `stylesheet=` setters
    # nil it to force the next cascade, including the assignment that clears the
    # stylesheet.
    @css_widgets_styled = false

    # Cached parsed document and the string it was parsed from, plus a
    # `data-uid -> node` index. Reused across cascades: an attribute-only change
    # patches nodes in place rather than re-parsing; a structural change forces
    # a fresh parse + index.
    @css_parsed_doc : HTML5::Node?
    @css_parsed_doc_string : String?
    @css_node_index : Hash(String, HTML5::Node)?
    # `data-uid -> {widget, slot}`, the widget-side twin of `@css_node_index`.
    # Rebuilt on the same structural signal (`@css_structural`) — its uid→widget
    # /slot mapping is stable while the tree structure is unchanged — so the
    # cascade stops re-walking the whole widget tree (and re-interning `uid::slot`
    # strings) on every attribute-only/hover/drag re-cascade.
    @css_widget_index : Hash(String, Tuple(Widget, String?))?

    # Cached parsed *structural* document (the `to_html(structural: true)`
    # variant, which omits sub-element pseudo-nodes) and the string it was
    # parsed from. Built only when a rule uses a backward/only structural pseudo
    # (`:last-child`, `:nth-last-child`, …) against a tree that has
    # sub-elements, and invalidated whenever the serialization changes.
    @css_structural_doc : HTML5::Node?
    @css_structural_doc_string : String?

    # Whether the cached widget index holds any sub-element/extra slot key
    # (`uid::slot`). Computed when the index is (re)built and invalidated with
    # it, so the cascade's backward-structural-pseudo path doesn't rescan every
    # index key on every re-cascade.
    @css_widget_index_has_slots = false

    # Cross-cascade `var()` caches: the custom properties merged across
    # the default and author stylesheets, and the per-value `var()` resolution
    # memo built against them. Both are a pure function of those two sheets — a
    # `Stylesheet`'s `variables` hash is populated only at parse time — so they
    # are rebuilt only when the author sheet object changes or the default
    # sheet's generation moves. The author sheet is remembered by *reference*
    # rather than `object_id` so a collected sheet's address can't be reused and
    # alias as a cache hit.
    @css_var_cache_sheet : CSS::Stylesheet?
    @css_var_cache_generation : Int32?
    @css_variables : Hash(String, String)?
    @css_resolved : Hash(String, String)?

    # Whether the widget tree *structure* changed (insert/remove) since the last
    # parse — if so the cached parse can't be patched and must be rebuilt.
    @css_structural = false

    # Widgets whose node attributes (class/id/state/intrinsic attrs) changed
    # since the last parse, to be patched into the cached document.
    @css_patch_widgets = Set(Widget).new

    # Assigns a stylesheet from CSS source text.
    def stylesheet=(css : String) : String
      @css_stylesheet = CSS::Stylesheet.parse(css)
      restyle # new stylesheet means everything may change
      @css_last_document = nil
      css
    end

    # Assigns an already-parsed stylesheet (or clears it with `nil` — which
    # also drops any `#add_stylesheet` layers).
    def stylesheet=(sheet : CSS::Stylesheet?) : CSS::Stylesheet?
      @css_stylesheet = sheet
      @css_extra_stylesheets.clear if sheet.nil?
      restyle
      @css_last_document = nil
      sheet
    end

    # Additional author-tier stylesheets layered over `#stylesheet` (a later
    # sheet wins equal-specificity ties). Composition for a theme fragment or
    # a component's rules that shouldn't replace the main sheet.
    @css_extra_stylesheets = [] of CSS::Stylesheet

    # Adds a stylesheet on top of the current one(s) without replacing them.
    # Returns the parsed sheet. Cleared by `self.stylesheet = nil`.
    def add_stylesheet(css : String) : CSS::Stylesheet
      add_stylesheet CSS::Stylesheet.parse(css)
    end

    # :ditto:
    def add_stylesheet(sheet : CSS::Stylesheet) : CSS::Stylesheet
      @css_extra_stylesheets << sheet
      restyle
      @css_last_document = nil
      # The `var()` merge derives from the sheet set; force its rebuild.
      @css_variables = nil
      @css_resolved = nil
      sheet
    end

    # Reused collection of `{sheet, owner}` pairs for every widget in the tree
    # carrying its own stylesheet (`Widget#stylesheet=`). Rebuilt per cascade;
    # also consulted (one cascade stale at worst) by the `css_dynamic_state?`/
    # `css_has_relational?`/`css_media_active?` probes.
    @css_widget_sheets_cache = [] of Tuple(CSS::Stylesheet, Widget)

    # A widget's own stylesheet set changed: force the next cascade (the CSS
    # document text doesn't encode sheets, so the byte-identical skip must not
    # swallow it).
    def css_widget_sheets_changed : Nil
      restyle
      @css_last_document = nil
    end

    # Rebuilds `@css_widget_sheets_cache` from the current tree.
    private def collect_css_widget_sheets : Array(Tuple(CSS::Stylesheet, Widget))
      list = @css_widget_sheets_cache
      list.clear
      @children.each do |top|
        top.self_and_each_descendant do |w|
          w.css_stylesheets.each { |sheet| list << {sheet, w} }
        end
      end
      list
    end

    # Whether `#load_stylesheet` automatically starts hot-reloading the loaded
    # file. Off by default; set to `true` *before* loading to enable.
    property? auto_reload_stylesheet = false

    # Path being watched for hot-reload, and the live watch handle.
    @css_watched_path : String?
    @css_watch : CSS::FileWatcher::Watch?

    # Raw text of the stylesheet last read from a file. Used to skip redundant
    # reparse/recascade/re-render on reload when the file content is unchanged.
    @css_loaded_source : String?

    # Loads (and applies on next render) a stylesheet from a `.css` file,
    # remembering the path for `#reload_stylesheet`/`#watch_stylesheet`. Unless
    # `#auto_reload_stylesheet?` is disabled, hot-reload is started for the file.
    def load_stylesheet(path : String) : Nil
      @css_stylesheet_path = path
      apply_stylesheet_source File.read(path), path
      watch_stylesheet path if auto_reload_stylesheet?
    end

    # Applies the startup stylesheet configured via `Config.colors_stylesheet`
    # (a `.css` file path or inline CSS text), unless this screen already has an
    # author stylesheet set in code — explicit assignment always wins. Must run
    # after the theme is installed, so configured author CSS layers over it.
    # Empty config value is a no-op.
    #
    # Treated as inline CSS when it contains a `{` (a rule body); otherwise a
    # file path (`~` expanded, `@import` resolved relative to it).
    protected def apply_config_stylesheet : Nil
      return unless @css_stylesheet.nil?
      source = Crysterm::Config.colors_stylesheet
      return if source.empty?
      if source.includes?('{')
        self.stylesheet = source
      else
        load_stylesheet Path[source].expand(home: true).to_s
      end
    end

    # Re-reads the file last given to `#load_stylesheet` and re-applies it
    # (leaving any active watcher in place).
    def reload_stylesheet : Nil
      @css_stylesheet_path.try { |path| apply_stylesheet_source File.read(path), path }
    end

    # Parses *source* (read from *path*, whose directory resolves `@import`) and
    # makes it the active stylesheet, remembering the raw text so an unchanged
    # reload can be skipped.
    private def apply_stylesheet_source(source : String, path : String) : Nil
      @css_loaded_source = source
      # A `.qss` (Qt Style Sheet) file is translated to Crysterm CSS first. The
      # raw text is what's cached above for the unchanged-reload check; only the
      # copy fed to the parser is rewritten.
      css = path.downcase.ends_with?(".qss") ? CSS::Qss.to_css(source) : source
      self.stylesheet = CSS::Stylesheet.parse(css, base_path: path)
    end

    # Starts stylesheet hot-reload for *path*: on each mtime change the file is
    # re-read and re-applied (`#reload_stylesheet` skips unchanged content), and
    # a repaint is scheduled. Any previous watch is stopped first.
    def watch_stylesheet(path : String? = @css_stylesheet_path) : Nil
      p = path || raise "no stylesheet path to watch (call load_stylesheet first)"
      unwatch_stylesheet
      @css_watched_path = p
      @css_watch = CSS::FileWatcher.watch(p) do
        # Runs in the watcher fiber; reload errors (partial saves, transient
        # read races) are swallowed by the watcher so the watch survives them.
        reload_stylesheet
        update
      end
      nil
    end

    # Stops stylesheet hot-reload.
    def unwatch_stylesheet : Nil
      @css_watch.try &.stop
      @css_watch = nil
      @css_watched_path = nil
    end

    # Marks the whole tree dirty so the cascade re-runs on the next render.
    def restyle : Nil
      @css_dirty = true
      @css_full = true
    end

    # Marks only the subtree affected by an *attribute* change to *widget* dirty
    # (its parent's subtree, so siblings — reachable via sibling combinators —
    # are covered), and records the widget's node for patching. A change to a
    # top-level widget can't be scoped (its siblings are other roots), so it
    # falls back to a full recompute.
    def restyle_subtree(widget : Widget) : Nil
      @css_dirty = true
      css_node_changed widget
      # `:has()` is an *upward* relation — the subject of `Form:has(.error)` is
      # typically an ancestor outside this widget's subtree — so a scoped
      # recompute would leave it stale. When any active sheet has relational
      # (`:has`) rules, recompute the whole tree instead.
      if css_has_relational?
        @css_full = true
      elsif parent = widget.parent
        @css_dirty_roots << parent
      else
        @css_full = true
      end
    end

    # Whether the active styling depends on `:has()` relational selectors (author
    # sheet first, then the default/theme sheet). When true, an attribute change
    # can affect an ancestor subject outside the changed subtree, so
    # `#restyle_subtree` falls back to a full recompute.
    def css_has_relational? : Bool
      return true if @css_stylesheet.try(&.has_relational?)
      return true if @css_extra_stylesheets.any?(&.has_relational?)
      return true if @css_widget_sheets_cache.any?(&.[0].has_relational?)
      CSS.default_stylesheet.has_relational?
    end

    # Marks a *structural* change to *widget*'s subtree: the cached parse can no
    # longer be patched (a node was added/removed), so it must be rebuilt.
    def restyle_structural(widget : Widget) : Nil
      @css_structural = true
      restyle_subtree widget
    end

    # Records that *widget*'s node attributes changed, so the cached parsed
    # document is patched (not re-parsed) for it. Tracked even for changes that
    # don't themselves invalidate styling (e.g. a non-dynamic state change), so
    # the cached document never drifts out of sync with the tree.
    def css_node_changed(widget : Widget) : Nil
      @css_patch_widgets << widget
    end

    # Whether the active styling depends on widget state via ancestor-state
    # selectors (e.g. `Form:focus Button`). When true, state transitions
    # invalidate styling so such rules re-evaluate; otherwise state changes need
    # no recascade (the per-state styles are precomputed).
    def css_dynamic_state? : Bool
      return true if @css_stylesheet.try(&.dynamic_state?)
      return true if @css_extra_stylesheets.any?(&.dynamic_state?)
      return true if @css_widget_sheets_cache.any?(&.[0].dynamic_state?)
      CSS.default_stylesheet.dynamic_state?
    end

    # Looks up parsed `@keyframes` *name* — the author stylesheet first, then the
    # default (theme) stylesheet — honoring any `@media` guard the definition
    # was declared under, evaluated against this terminal's current metrics
    # (the same metrics `Cascade.apply_sheets` feeds rule-level `@media`).
    def css_keyframes(name : String) : Array(Tuple(Float64, Hash(String, String)))?
      media_colors = begin
        color_count.to_i32
      rescue
        0x1000000
      end
      media_glyphs = glyph_tier.value.to_i32
      @css_stylesheet.try(&.keyframes_for(name, width, height, media_colors, media_glyphs)) ||
        CSS.default_stylesheet.keyframes_for(name, width, height, media_colors, media_glyphs)
    end

    # Notes that *element*'s subtree, arriving from another window, may carry
    # widgets a previous window's cascade styled. The revert-to-pristine pass is
    # gated on the per-window `@css_widgets_styled` flag, so without flipping it
    # a widget styled on window A and moved to a rule-less window B would keep
    # A's computed styles forever.
    def css_note_styled_attach(element : Widget) : Nil
      return if @css_widgets_styled
      styled = false
      element.self_and_each_descendant do |el|
        styled ||= el.css_styled?
      end
      @css_widgets_styled = true if styled
    end

    # Runs the cascade immediately against the current tree. Skips entirely when
    # the CSS document is byte-identical to the last run, and otherwise
    # recomputes only the dirty subtrees (or the whole tree when a full
    # recompute was requested).
    def apply_stylesheet : Nil
      author = @css_stylesheet
      default = CSS.default_stylesheet
      widget_sheets = collect_css_widget_sheets
      # CSS is active whenever an author sheet (window-level or `add_stylesheet`
      # layer), a widget's own sheet, or the default (theme) stylesheet has
      # rules; with none, widgets keep their programmatic look.
      if (author.nil? || author.rules.empty?) && default.rules.empty? &&
         @css_extra_stylesheets.all?(&.rules.empty?) &&
         widget_sheets.all?(&.[0].rules.empty?)
        # No active rules: nothing to cascade. But a previous cascade's widgets
        # must not keep their computed styles — assigning a stylesheet restyles
        # everything, so clearing it must too. The cascade's reset-to-pristine
        # pass isn't reached with no rules, so revert here.
        css_reset_styled_widgets if @css_widgets_styled
        @css_last_default_generation = CSS.default_stylesheet_generation
        # Clear only the dirty/scope flags, keeping `@css_structural`/
        # `@css_patch_widgets` and the parse cache: changes made during this
        # unstyled period must still be reflected when a stylesheet is
        # (re)assigned, or the next active cascade patches a stale cached
        # document against an empty patch set.
        clear_css_dirty_scope
        return
      end
      document = to_html
      # The skip identity is compared field-wise against the previous run's
      # values, not folded into one string: prefixing the scalars onto the
      # serialized document would allocate and memcpy a whole extra copy of it
      # on every cascade — i.e. on every hover/drag/focus event. So snapshot the
      # previous values before the eager assignments below overwrite them.
      media = css_media_active?
      size = {width, height}
      tier = glyph_tier
      generation = CSS.default_stylesheet_generation
      prev_document = @css_last_document
      prev_size = @css_last_size
      prev_tier = @css_last_glyph_tier
      prev_generation = @css_last_default_generation
      @css_last_size = size
      @css_last_glyph_tier = tier
      @css_last_default_generation = generation
      # Skip only when every input the cascade's outcome depends on is
      # unchanged:
      #
      # * the document text, always;
      # * the default-sheet generation, always — a runtime theme swap leaves the
      #   document byte-identical, and even an explicit `restyle` would
      #   otherwise be swallowed by this skip;
      # * the terminal size and glyph tier, only while media rules are active.
      #   The document encodes uids/classes/attributes but *not* the size or
      #   tier, so an `@media`-guarded cascade is byte-identical across a resize
      #   or an `@media (glyphs: …)` tier switch and would be wrongly skipped.
      #
      # A mid-run change of `css_media_active?` itself only happens via a
      # stylesheet change: the `stylesheet=` setters nil `@css_last_document`
      # and a default-sheet swap bumps the generation, so either way this
      # doesn't skip.
      if document == prev_document && generation == prev_generation &&
         (!media || (prev_size == size && prev_tier == tier))
        clear_css_dirty
        return
      end
      @css_last_document = document
      scope = (@css_full || @css_dirty_roots.empty?) ? nil : css_scope_widgets
      doc = css_parsed_document(document)
      variables, resolved = css_var_caches(author, default, generation)
      # Sheet list, lowest tier first: default (theme), then the window-level
      # author sheet plus any `add_stylesheet` layers, then each widget's own
      # sheets — the latter scoped to their owner's subtree.
      sheets = Array(Tuple(CSS::Stylesheet, Int32, Widget?)).new(2 + @css_extra_stylesheets.size + widget_sheets.size)
      sheets << {default, CSS::Cascade::TIER_DEFAULT, nil}
      author.try { |sheet| sheets << {sheet, CSS::Cascade::TIER_AUTHOR, nil} }
      @css_extra_stylesheets.each { |sheet| sheets << {sheet, CSS::Cascade::TIER_AUTHOR, nil} }
      widget_sheets.each { |(sheet, owner)| sheets << {sheet, CSS::Cascade::TIER_WIDGET, owner} }
      CSS::Cascade.apply_sheets sheets, self, doc, scope, variables, resolved
      @css_widgets_styled = true
      clear_css_dirty
    end

    # The `{merged variables, var() resolution memo}` pair the cascade resolves
    # `var(...)` with, cached across cascades and rebuilt only when the sheets
    # they derive from change (see `@css_variables`). The merge order mirrors the
    # tier order `Cascade.apply` feeds — default first, author over it — so a
    # later sheet's custom properties win.
    private def css_var_caches(author : CSS::Stylesheet?, default : CSS::Stylesheet, generation : Int32) : Tuple(Hash(String, String), Hash(String, String))
      variables = @css_variables
      resolved = @css_resolved
      if variables && resolved && generation == @css_var_cache_generation && css_var_cache_built_from?(author)
        return {variables, resolved}
      end
      variables = {} of String => String
      variables.merge! default.variables
      author.try { |sheet| variables.merge! sheet.variables }
      # `add_stylesheet` layers merge over the main author sheet (later wins);
      # `add_stylesheet` nils the caches, so this rebuild sees every layer.
      # Widget-scoped sheets' variables are deliberately absent: the merge is
      # document-global, and a subtree-scoped `--x` would leak tree-wide.
      @css_extra_stylesheets.each { |sheet| variables.merge! sheet.variables }
      resolved = {} of String => String
      @css_variables = variables
      @css_resolved = resolved
      @css_var_cache_sheet = author
      @css_var_cache_generation = generation
      {variables, resolved}
    end

    # Whether the cached `var()` tables were built from *author* (reference
    # identity; a `nil` author matches only a `nil` cached sheet).
    private def css_var_cache_built_from?(author : CSS::Stylesheet?) : Bool
      cached = @css_var_cache_sheet
      return cached.nil? if author.nil?
      !cached.nil? && cached.same?(author)
    end

    # Builds the "no theme" `CSS::Theme` for this screen from its terminal's
    # probed colors (default background/foreground and 16-color palette). Values
    # the terminal didn't report are filled in from the built-in dark theme; an
    # undetected surface/text is left as the terminal default so the native
    # background shows through.
    def terminal_theme : CSS::Theme
      f = tput.features
      palette = f.palette.map { |c| css_rgb_to_i(c) }
      CSS::Theme.from_terminal css_rgb_to_i(f.default_background), css_rgb_to_i(f.default_foreground), palette
    end

    # Converts a `tput` `RGB` record (or `nil`) to a native `0xRRGGBB` int.
    private def css_rgb_to_i(rgb) : Int32?
      rgb.try { |c| Colors.rgb(c.r, c.g, c.b) }
    end

    # Returns the parsed document for *document*. A structural change (or no
    # cache) forces a fresh parse + node index. Otherwise the cached parse is
    # reused: identical when the string matches, or patched in place per changed
    # widget's node, avoiding a re-parse on attribute-only changes.
    private def css_parsed_document(document : String) : HTML5::Node
      cached = @css_parsed_doc
      if @css_structural || cached.nil?
        parsed = HTML5.parse(document)
        @css_parsed_doc = parsed
        @css_parsed_doc_string = document
        @css_node_index = css_build_node_index(parsed)
        return parsed
      end
      unless document == @css_parsed_doc_string
        css_patch_nodes
        @css_parsed_doc_string = document
      end
      cached
    end

    # Returns the cached widget index (`data-uid -> {widget, slot}`), rebuilding
    # via the yielded builder on a structural change or first use. Gated on the
    # same `@css_structural` flag as `@css_node_index`: the two indexes share an
    # invalidation condition (a sub-element/slot or tree-shape change stales
    # both), and a structural change always changes the document identity, so the
    # skip path in `#apply_stylesheet` can't clear the flag out from under a
    # pending rebuild. The block is only `yield`ed (never stored), so a cache hit
    # allocates nothing.
    def css_widget_index(& : -> Hash(String, Tuple(Widget, String?))) : Hash(String, Tuple(Widget, String?))
      cached = @css_widget_index
      if @css_structural || cached.nil?
        built = yield
        @css_widget_index = built
        # Slot keys can only appear/disappear with the index itself, so the
        # cascade's "does this tree have sub-elements at all?" test is answered
        # once here instead of rescanning every key on every cascade.
        @css_widget_index_has_slots = built.any? { |key, _| key.includes?("::") }
        built
      else
        cached
      end
    end

    # Whether the widget index holds any sub-element/extra slot (`uid::slot`)
    # key. Valid once `#css_widget_index` has been called (which the cascade
    # does before reading this).
    def css_widget_index_has_slots? : Bool
      @css_widget_index_has_slots
    end

    # The parsed *structural* document (`to_html(structural: true)`), cached
    # across cascades. Built only when a backward/only structural pseudo
    # (`:last-child`, …) must be matched against a tree with sub-elements.
    #
    # Invalidation is a byte-compare of the serialization against the cached
    # string; any difference re-parses. Deliberately coarser than the main
    # cache: it has no attribute-only in-place patch path. This doc is built
    # only on the cascades where such a rule fires, so `@css_structural` may be
    # cleared on a cascade that never built it — a patch path keyed on that flag
    # could miss a real structural change, while the string compare cannot.
    def css_structural_document : HTML5::Node
      document = to_html(structural: true)
      if (cached = @css_structural_doc) && document == @css_structural_doc_string
        return cached
      end
      parsed = HTML5.parse(document)
      @css_structural_doc = parsed
      @css_structural_doc_string = document
      parsed
    end

    # Patches the cached document's changed nodes in place: each tracked widget's
    # node has its attributes replaced with the widget's current ones.
    private def css_patch_nodes : Nil
      index = @css_node_index
      return unless index
      @css_patch_widgets.each do |widget|
        node = index[widget.uid_s]?
        next unless node
        node.attr.clear
        node.attr.concat widget.css_node_attributes
        # The widget's sub-element pseudo-nodes repeat its intrinsic attributes
        # (`[checked]` on the checkbox's Indicator), so an attribute-only change
        # must refresh them too or `::indicator:checked` rules would match
        # against the stale toggle state.
        widget.css_sub_elements.each do |slot|
          sub = index["#{widget.uid_s}::#{slot}"]?
          next unless sub
          sub.attr.clear
          sub.attr.concat widget.css_sub_node_attributes(slot)
        end
      end
    end

    # Builds a `data-uid -> node` index over a parsed document.
    private def css_build_node_index(doc : HTML5::Node) : Hash(String, HTML5::Node)
      index = {} of String => HTML5::Node
      css_each_node(doc) do |node|
        node["data-uid"]?.try { |attr| index[attr.val] = node }
      end
      index
    end

    private def css_each_node(node : HTML5::Node, &block : HTML5::Node ->) : Nil
      block.call node
      child = node.first_child
      while child
        css_each_node child, &block
        child = child.next_sibling
      end
    end

    private def clear_css_dirty : Nil
      clear_css_dirty_scope
      @css_structural = false
      @css_patch_widgets.clear
    end

    # Reverts every widget to its pristine pre-CSS look
    # (`Widget#css_reset_to_base`) — the cascade's own reset, minus the
    # re-apply. Run when styling transitions to "no active rules" after a
    # cascade styled widgets. Also drops `@css_last_document`, so a later
    # re-assigned stylesheet recascades from scratch.
    private def css_reset_styled_widgets : Nil
      # `each_descendant` on the window is the whole widget tree, pre-order
      # (the window itself is not a widget).
      each_descendant &.css_reset_to_base
      @css_widgets_styled = false
      @css_last_document = nil
    end

    # Clears only the dirty/scope flags, leaving the structural-change and
    # per-widget patch tracking (and the parse cache) untouched. Used by the
    # no-rules early exit in `#apply_stylesheet`, which must not discard
    # invalidation state accumulated while no stylesheet is active.
    private def clear_css_dirty_scope : Nil
      @css_dirty = false
      @css_full = false
      @css_dirty_roots.clear
    end

    # Expands the dirty subtree roots into the full set of widgets to recompute.
    private def css_scope_widgets : Set(Widget)
      widgets = Set(Widget).new
      @css_dirty_roots.each do |root|
        root.self_and_each_descendant { |w| widgets << w }
      end
      widgets
    end

    # Whether any active sheet (author, or the default/theme) has `@media` rules,
    # so a resize must re-run the cascade to re-evaluate their conditions.
    def css_media_active? : Bool
      return true if @css_stylesheet.try(&.has_media?)
      return true if @css_extra_stylesheets.any?(&.has_media?)
      return true if @css_widget_sheets_cache.any?(&.[0].has_media?)
      CSS.default_stylesheet.has_media?
    end

    # Runs the cascade if styling is dirty. Also re-runs after a terminal resize
    # when media-guarded rules are active, and after a default-stylesheet
    # (theme) swap: neither marks anything dirty, yet both can change which
    # rules apply, so each forces a full recompute.
    protected def apply_stylesheet_if_dirty : Nil
      if @css_dirty
        apply_stylesheet
      elsif (css_media_active? && (@css_last_size != {width, height} || @css_last_glyph_tier != glyph_tier)) ||
            @css_last_default_generation != CSS.default_stylesheet_generation
        @css_dirty = true
        @css_full = true
        apply_stylesheet
      end
    end
  end
end
