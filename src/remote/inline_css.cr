module Crysterm
  # Inline-`<style>` support for self-contained layouts — part of the remote
  # subsystem, compiled only with `-Dremote`. Reopens `Window` to keep an inline
  # CSS source (extracted from a loaded layout's `<style>` by `DOM.load`)
  # alongside the external file/string source, recomposing both into the active
  # stylesheet. The core `Window` (in `style/css/window.cr`) has no knowledge of
  # this; these overrides supersede its plain versions when present.
  class Window
    # CSS pulled from inline `<style>` blocks in a loaded layout. Kept separate
    # from the external source so each can change independently (file hot-reload,
    # layout hot-reload).
    @css_inline_source : String?

    # Overrides the core setter to *record* the external source (so it can be
    # recomposed with the inline source), instead of applying it directly.
    def stylesheet=(css : String) : String
      @css_loaded_source = css
      recompose_stylesheet
      css
    end

    # Overrides the core file-source application to compose with inline CSS, so
    # external/file hot-reload keeps any inline `<style>` rules.
    private def apply_stylesheet_source(source : String, path : String) : Nil
      # Translate a `.qss` file to Crysterm CSS first, like the core
      # `apply_stylesheet_source`, so `recompose_stylesheet` parses real CSS.
      # Without this, raw QSS was fed straight to the CSS parser and silently
      # matched nothing.
      @css_loaded_source = path.downcase.ends_with?(".qss") ? CSS::Qss.to_css(source) : source
      recompose_stylesheet path
    end

    # Sets the inline-`<style>` stylesheet source and recomposes. Inline rules
    # come after the external source, so they win on equal specificity (like a
    # `<style>` block after a linked sheet in a browser). Empty string clears it.
    def add_inline_stylesheet(css : String) : Nil
      @css_inline_source = css.presence
      recompose_stylesheet @css_stylesheet_path
    end

    # Builds the active stylesheet from external source + inline source,
    # concatenated and handed to the one CSS parser. No-op if neither is set.
    private def recompose_stylesheet(base_path : String? = nil) : Nil
      external = @css_loaded_source
      inline = @css_inline_source
      combined =
        if external && inline
          "#{external}\n#{inline}"
        else
          external || inline
        end
      # `combined.nil?` here means a *cleared* source (e.g. a hot-reload to a
      # layout with no `<style>` and no external sheet): parse an empty document
      # so the previously composed rules are dropped rather than left stale. An
      # early return would leave the old inline CSS active.
      self.stylesheet = CSS::Stylesheet.parse(combined || "", base_path: base_path)
    end
  end
end
