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

    # Assigns a stylesheet from CSS source text.
    def stylesheet=(css : String) : String
      @css_stylesheet = CSS::Stylesheet.parse(css)
      @css_dirty = true
      css
    end

    # Assigns an already-parsed stylesheet (or clears it with `nil`).
    def stylesheet=(sheet : CSS::Stylesheet?) : CSS::Stylesheet?
      @css_stylesheet = sheet
      @css_dirty = true
      sheet
    end

    # Marks styling dirty so the cascade re-runs on the next render. Call after
    # changing the widget tree or a widget's `css_classes`/`css_id`, since the
    # cascade is not (yet) auto-invalidated on those changes.
    def restyle : Nil
      @css_dirty = true
    end

    # Runs the cascade immediately against the current tree, regardless of the
    # dirty flag.
    def apply_stylesheet : Nil
      if sheet = @css_stylesheet
        CSS::Cascade.apply sheet, self
      end
      @css_dirty = false
    end

    # Runs the cascade if styling is dirty. Invoked from the render path.
    protected def apply_stylesheet_if_dirty : Nil
      apply_stylesheet if @css_dirty
    end
  end
end
