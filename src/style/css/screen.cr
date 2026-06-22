module Crysterm
  class Screen
    # The stylesheet driving CSS styling for this screen, if any. Assigning one
    # (as text or a parsed `CSS::Stylesheet`) marks styling dirty; the cascade
    # runs on the next render. With no stylesheet set, nothing changes and
    # widgets keep their programmatic styles.
    getter css_stylesheet : CSS::Stylesheet?

    # Whether styling needs recomputing on the next render.
    getter? css_dirty = false

    # The screen is the styling root, so a structural change on it invalidates
    # its own styling directly (overrides the `Mixin::Children` no-op hook).
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
      @css_dirty = true
      @css_last_document = nil
      css
    end

    # Assigns an already-parsed stylesheet (or clears it with `nil`).
    def stylesheet=(sheet : CSS::Stylesheet?) : CSS::Stylesheet?
      @css_stylesheet = sheet
      @css_dirty = true
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

    # Marks styling dirty so the cascade re-runs on the next render. Call after
    # changing the widget tree or a widget's `css_classes`/`css_id`, since the
    # cascade is not (yet) auto-invalidated on those changes.
    def restyle : Nil
      @css_dirty = true
    end

    # Whether the active styling depends on widget state via ancestor-state
    # selectors (e.g. `Form:focus Button`). When true, state transitions
    # invalidate styling so such rules re-evaluate; otherwise state changes need
    # no recascade (the per-state styles are precomputed).
    def css_dynamic_state? : Bool
      return true if @css_stylesheet.try(&.dynamic_state?)
      CSS.default_stylesheet.dynamic_state?
    end

    # Runs the cascade immediately against the current tree, regardless of the
    # dirty flag. Skips the work when the CSS document is byte-identical to the
    # last run (nothing selector-relevant changed since).
    def apply_stylesheet : Nil
      @css_dirty = false
      sheet = @css_stylesheet
      return unless sheet
      document = to_html
      return if document == @css_last_document
      @css_last_document = document
      CSS::Cascade.apply sheet, self, document
    end

    # Runs the cascade if styling is dirty. Invoked from the render path.
    protected def apply_stylesheet_if_dirty : Nil
      apply_stylesheet if @css_dirty
    end
  end
end
