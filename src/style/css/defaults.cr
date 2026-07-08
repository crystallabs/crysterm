module Crysterm
  module CSS
    # The default ("user-agent") stylesheet.
    #
    # Applied beneath all author rules (cascade tier `TIER_DEFAULT`) as a
    # baseline that author stylesheets override. Empty by default — set it once
    # at startup to express widget default looks as CSS:
    #
    # ```
    # Crysterm::CSS.default_stylesheet = <<-CSS
    #   Scrollbar { color: gray; }
    #   Button    { border: solid; }
    # CSS
    # ```
    #
    # Being tier 0, every rule here is overridable by a user `Button { ... }`
    # rule. Only participates when a window has its own stylesheet set (CSS
    # stays opt-in); with no author stylesheet, nothing is applied.
    @@default_stylesheet = Stylesheet.new

    # Monotonic generation of the default stylesheet, bumped by every
    # assignment (including a theme install, which goes through
    # `default_stylesheet=`). `Window#apply_stylesheet` folds it into its
    # cascade-skip identity and `#apply_stylesheet_if_dirty` treats a mismatch
    # like a media-relevant resize — the serialized widget document encodes
    # nothing about which rules are active, so without this a runtime theme /
    # default-sheet swap would never invalidate existing windows.
    @@default_stylesheet_generation = 0

    # The current default stylesheet.
    def self.default_stylesheet : Stylesheet
      @@default_stylesheet
    end

    # :ditto:
    def self.default_stylesheet_generation : Int32
      @@default_stylesheet_generation
    end

    # Sets the default stylesheet from CSS text.
    def self.default_stylesheet=(css : String) : Stylesheet
      @@default_stylesheet_generation += 1
      @@default_stylesheet = Stylesheet.parse(css)
    end

    # Sets the default stylesheet from an already-parsed `Stylesheet`.
    def self.default_stylesheet=(sheet : Stylesheet) : Stylesheet
      @@default_stylesheet_generation += 1
      @@default_stylesheet = sheet
    end
  end
end
