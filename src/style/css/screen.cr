module Crysterm
  class Screen
    # The stylesheet driving CSS styling for this screen, if any. Assigning one
    # (as text or a parsed `CSS::Stylesheet`) marks styling dirty; the cascade
    # runs on the next render. With no stylesheet set, nothing changes and
    # widgets keep their programmatic styles.
    getter css_stylesheet : CSS::Stylesheet?

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
    # `#watch_stylesheet`. Set by `#load_stylesheet`.
    getter css_stylesheet_path : String?

    # Caches the last CSS document the cascade ran against, so an
    # `#apply_stylesheet` whose document is byte-identical (nothing
    # selector-relevant changed) is skipped. Reset whenever the *stylesheet*
    # itself changes (the document doesn't encode the rules).
    @css_last_document : String?

    # Cached *parsed* document and the string it was parsed from, plus a
    # `data-uid -> node` index into it. The parse is reused across cascades: on
    # an attribute-only change the changed nodes are *patched* in place (see
    # `@css_patch_widgets`) rather than re-parsing; a structural change
    # (`@css_structural`) forces a fresh parse + index.
    @css_parsed_doc : HTML5::Node?
    @css_parsed_doc_string : String?
    @css_node_index : Hash(String, HTML5::Node)?

    # Whether the widget tree *structure* changed (insert/remove) since the last
    # parse — if so the cached parse can't be patched and must be rebuilt.
    @css_structural = false

    # Widgets whose node attributes (class/id/state/intrinsic attrs) changed
    # since the last parse, to be patched into the cached document.
    @css_patch_widgets = Set(Widget).new

    # Assigns a stylesheet from CSS source text.
    def stylesheet=(css : String) : String
      @css_stylesheet = CSS::Stylesheet.parse(css)
      restyle # a new stylesheet means everything may change
      @css_last_document = nil
      css
    end

    # Assigns an already-parsed stylesheet (or clears it with `nil`).
    def stylesheet=(sheet : CSS::Stylesheet?) : CSS::Stylesheet?
      @css_stylesheet = sheet
      restyle
      @css_last_document = nil
      sheet
    end

    # Whether `#load_stylesheet` automatically starts hot-reloading the loaded
    # file (see `#watch_stylesheet`). On by default; set to `false` *before*
    # loading to opt out.
    property? auto_reload_stylesheet = true

    # File-watching is temporarily disabled (the `fswatch` shard was removed),
    # so no live watcher is held. Kept as a path placeholder for the eventual
    # re-integration via `event_handler`.
    @css_watched_path : String?

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
    # author stylesheet set in code — explicit assignment always wins. Called
    # once from the constructor, after the theme is installed, so the configured
    # author CSS layers over the theme. An empty config value is a no-op.
    #
    # The value is treated as inline CSS when it contains a `{` (a rule body);
    # otherwise it's a file path (`~` expanded, `@import` resolved relative to
    # it).
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
      # A `.qss` (Qt Style Sheet) file is translated to Crysterm CSS first — the
      # `Q` selector prefix is stripped and Qt class names are mapped to ours
      # (see `CSS::Qss`). The raw text is what's cached above for the
      # unchanged-reload check; only the copy fed to the parser is rewritten.
      # Anything still unrecognised is skipped by the parser, never fatal.
      css = path.downcase.ends_with?(".qss") ? CSS::Qss.to_css(source) : source
      self.stylesheet = CSS::Stylesheet.parse(css, base_path: path)
    end

    # Stylesheet hot-reload. Temporarily DISABLED: the `fswatch` shard was
    # removed, so this no longer starts a file watcher. It remains callable (and
    # is still invoked by `#load_stylesheet` when `#auto_reload_stylesheet?`) so
    # call sites keep working; it just records the path and returns without
    # watching. To reload manually, call `#reload_stylesheet`. Hot-reload is to
    # be re-introduced via `event_handler`.
    def watch_stylesheet(path : String? = @css_stylesheet_path) : Nil
      @css_watched_path = path || raise "no stylesheet path to watch (call load_stylesheet first)"
      nil
    end

    # Stops stylesheet hot-reload. No-op while file-watching is disabled.
    def unwatch_stylesheet : Nil
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
      if parent = widget.parent
        @css_dirty_roots << parent
      else
        @css_full = true
      end
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
      CSS.default_stylesheet.dynamic_state?
    end

    # Looks up parsed `@keyframes` *name* — the author stylesheet first, then the
    # default (theme) stylesheet. Used by the widget CSS-animation driver.
    def css_keyframes(name : String) : Array(Tuple(Float64, Hash(String, String)))?
      @css_stylesheet.try(&.keyframes[name]?) || CSS.default_stylesheet.keyframes[name]?
    end

    # Runs the cascade immediately against the current tree. Skips entirely when
    # the CSS document is byte-identical to the last run, and otherwise
    # recomputes only the dirty subtrees (or the whole tree when a full
    # recompute was requested).
    def apply_stylesheet : Nil
      author = @css_stylesheet
      default = CSS.default_stylesheet
      # CSS is active whenever *either* an author stylesheet or the default
      # (theme) stylesheet has rules. With neither, nothing is styled and
      # widgets keep their programmatic look.
      if (author.nil? || author.rules.empty?) && default.rules.empty?
        clear_css_dirty
        return
      end
      document = to_html
      if document == @css_last_document
        clear_css_dirty
        return
      end
      @css_last_document = document
      scope = (@css_full || @css_dirty_roots.empty?) ? nil : css_scope_widgets
      doc = css_parsed_document(document)
      # `Cascade.apply` folds the default stylesheet in beneath the author one;
      # with no author sheet we run the default (theme) by itself.
      if author
        CSS::Cascade.apply author, self, doc, scope
      else
        CSS::Cascade.apply_sheets [{default, CSS::Cascade::TIER_DEFAULT}], self, doc, scope
      end
      clear_css_dirty
    end

    # Builds the "no theme" `CSS::Theme` for *this* screen from its terminal's
    # probed colors (default background/foreground and 16-color palette). Any
    # value the terminal didn't report is filled in from the built-in dark
    # theme, and an undetected surface/text is left as the terminal default so
    # the native background shows through.
    def terminal_theme : CSS::Theme
      f = tput.features
      palette = f.palette.map { |c| css_rgb_to_i(c) }
      CSS::Theme.from_terminal css_rgb_to_i(f.default_background), css_rgb_to_i(f.default_foreground), palette
    end

    # Converts a `tput` `RGB` record (or `nil`) to a native `0xRRGGBB` int.
    private def css_rgb_to_i(rgb) : Int32?
      rgb.try { |c| (c.r.to_i32 << 16) | (c.g.to_i32 << 8) | c.b.to_i32 }
    end

    # Returns the parsed document for *document*. A structural change (or no
    # cache) forces a fresh parse + node index. Otherwise the cached parse is
    # reused: identical when the string matches (stylesheet-only change), or
    # patched in place — node by node — for the widgets whose attributes changed,
    # avoiding a re-parse on attribute-only changes (incremental matching).
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
      @css_dirty = false
      @css_full = false
      @css_structural = false
      @css_dirty_roots.clear
      @css_patch_widgets.clear
    end

    # Expands the dirty subtree roots into the full set of widgets to recompute.
    private def css_scope_widgets : Set(Widget)
      widgets = Set(Widget).new
      @css_dirty_roots.each { |root| collect_css_subtree root, widgets }
      widgets
    end

    private def collect_css_subtree(widget : Widget, into : Set(Widget)) : Nil
      into << widget
      widget.children.each { |child| collect_css_subtree child, into }
    end

    # Runs the cascade if styling is dirty. Invoked from the render path.
    protected def apply_stylesheet_if_dirty : Nil
      apply_stylesheet if @css_dirty
    end
  end
end
