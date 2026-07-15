module Crysterm
  # Inline-`<style>` support for self-contained layouts, compiled only with
  # `-Dremote`. Reopens `Window` to keep an inline CSS source, extracted from a
  # loaded layout's `<style>`, alongside the external file/string source, and
  # recomposes both into the active stylesheet. The core `Window` knows nothing
  # of this; these overrides supersede its plain versions when present.
  class Window
    # CSS pulled from inline `<style>` blocks in a loaded layout. Kept separate
    # from the external source so each can change independently (file hot-reload,
    # layout hot-reload).
    @css_inline_source : String?

    # A stylesheet assigned as an *already-parsed* object, recorded so a later
    # inline recompose (triggered by any `load_layout`/`reload_layout`) doesn't
    # silently discard it: the other two tracked sources are text only.
    @css_object_source : CSS::Stylesheet?

    # True while `recompose_stylesheet` applies its own composed result, so the
    # `stylesheet=(CSS::Stylesheet?)` override below doesn't mistake that
    # internal apply for a user-assigned object source (which would record — and
    # then re-merge — the recompose output into itself).
    @recomposing = false

    # Overrides the core setter to *record* the external source (so it can be
    # recomposed with the inline source), instead of applying it directly.
    def stylesheet=(css : String) : String
      @css_loaded_source = css
      recompose_stylesheet
      css
    end

    # Overrides the core object setter to *record* a parsed stylesheet as a
    # tracked source — unless the assignment is `recompose_stylesheet`'s own
    # internal apply — then applies it via the core `previous_def`.
    def stylesheet=(sheet : CSS::Stylesheet?) : CSS::Stylesheet?
      @css_object_source = sheet unless @recomposing
      previous_def(sheet)
    end

    # Overrides the core file-source application to compose with inline CSS, so
    # external/file hot-reload keeps any inline `<style>` rules.
    private def apply_stylesheet_source(source : String, path : String) : Nil
      # A `.qss` file must be translated to Crysterm CSS first, or raw QSS
      # reaches the CSS parser and silently matches nothing.
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
    # concatenated and handed to the one CSS parser, then merges in any
    # object-assigned author sheet. No-op if nothing is set.
    private def recompose_stylesheet(base_path : String? = nil) : Nil
      external = @css_loaded_source
      inline = @css_inline_source
      combined =
        if external && inline
          "#{external}\n#{inline}"
        else
          external || inline
        end
      object = @css_object_source

      sheet =
        if combined
          parsed = CSS::Stylesheet.parse(combined, base_path: base_path)
          # Object sheet acts like the external/linked sheet: text (inline)
          # rules come after it, so they win on equal specificity.
          object ? merge_stylesheet(object, parsed) : parsed
        elsif object
          # No text source, but an object sheet was assigned: keep it verbatim
          # rather than clobbering it with an empty parse.
          object
        else
          # Everything cleared (e.g. a hot-reload to a `<style>`-less layout with
          # no external/object sheet): parse an empty document so previously
          # composed rules are dropped rather than left stale.
          CSS::Stylesheet.parse("", base_path: base_path)
        end

      @recomposing = true
      self.stylesheet = sheet
      @recomposing = false
    end

    # Combines two parsed stylesheets into one, `base` first so `extra`'s rules
    # win on equal specificity, layering the recomposed text sources over an
    # object-assigned author sheet without needing that sheet's source text.
    private def merge_stylesheet(base : CSS::Stylesheet, extra : CSS::Stylesheet) : CSS::Stylesheet
      CSS::Stylesheet.new(
        base.rules + extra.rules,
        base.variables.merge(extra.variables),
        base.warnings + extra.warnings,
        base.keyframes.merge(extra.keyframes),
      )
    end
  end
end
