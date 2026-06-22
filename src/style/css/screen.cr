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

    # Path the active stylesheet was loaded from, for `#reload_stylesheet` /
    # `#watch_stylesheet`. Set by `#load_stylesheet`.
    getter css_stylesheet_path : String?

    # Caches the last CSS document the cascade ran against, so an
    # `#apply_stylesheet` whose document is byte-identical (nothing
    # selector-relevant changed) is skipped. Reset whenever the *stylesheet*
    # itself changes (the document doesn't encode the rules).
    @css_last_document : String?

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

    # Loads (and applies on next render) a stylesheet from a `.css` file,
    # remembering the path for `#reload_stylesheet`/`#watch_stylesheet`.
    def load_stylesheet(path : String) : Nil
      @css_stylesheet_path = path
      self.stylesheet = File.read(path)
    end

    # Re-reads the file last given to `#load_stylesheet` and re-applies it.
    def reload_stylesheet : Nil
      @css_stylesheet_path.try { |path| load_stylesheet path }
    end

    # Watches the stylesheet file for changes (polling *interval*), reloading and
    # re-rendering on each modification — a simple hot-reload for theme authoring.
    # Returns the spawned `Fiber`. Read/parse errors during editing are ignored.
    def watch_stylesheet(path : String? = @css_stylesheet_path, interval : Time::Span = 1.second) : Fiber
      watched = path || raise "no stylesheet path to watch (call load_stylesheet first)"
      last = File.info?(watched).try &.modification_time
      spawn do
        loop do
          sleep interval
          info = File.info?(watched)
          next unless info
          if last.nil? || info.modification_time != last
            last = info.modification_time
            begin
              load_stylesheet watched
              render
            rescue
              # mid-edit read/parse error; try again next tick
            end
          end
        end
      end
    end

    # Marks the whole tree dirty so the cascade re-runs on the next render.
    def restyle : Nil
      @css_dirty = true
      @css_full = true
    end

    # Marks only the subtree affected by a change to *widget* dirty (its parent's
    # subtree, so siblings — reachable via sibling combinators — are covered).
    # A change to a top-level widget can't be scoped (its siblings are other
    # roots), so it falls back to a full recompute.
    def restyle_subtree(widget : Widget) : Nil
      @css_dirty = true
      if parent = widget.parent
        @css_dirty_roots << parent
      else
        @css_full = true
      end
    end

    # Whether the active styling depends on widget state via ancestor-state
    # selectors (e.g. `Form:focus Button`). When true, state transitions
    # invalidate styling so such rules re-evaluate; otherwise state changes need
    # no recascade (the per-state styles are precomputed).
    def css_dynamic_state? : Bool
      return true if @css_stylesheet.try(&.dynamic_state?)
      CSS.default_stylesheet.dynamic_state?
    end

    # Runs the cascade immediately against the current tree. Skips entirely when
    # the CSS document is byte-identical to the last run, and otherwise
    # recomputes only the dirty subtrees (or the whole tree when a full
    # recompute was requested).
    def apply_stylesheet : Nil
      sheet = @css_stylesheet
      unless sheet
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
      CSS::Cascade.apply sheet, self, document, scope
      clear_css_dirty
    end

    private def clear_css_dirty : Nil
      @css_dirty = false
      @css_full = false
      @css_dirty_roots.clear
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
