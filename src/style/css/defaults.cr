module Crysterm
  module CSS
    # The default ("user-agent") stylesheet.
    #
    # Applied beneath all author rules (cascade tier `TIER_DEFAULT`) as a
    # baseline that author stylesheets override. Empty by default:
    #
    # ```
    # Crysterm::CSS.default_stylesheet = <<-CSS
    #   Scrollbar { color: gray; }
    #   Button    { border: solid; }
    # CSS
    # ```
    #
    # Only participates when a window has its own stylesheet set (CSS stays
    # opt-in); with no author stylesheet, nothing is applied.
    @@default_stylesheet = Stylesheet.new

    # Monotonic generation, bumped by every assignment. Windows fold it into
    # their cascade-skip identity: nothing else distinguishes a runtime theme /
    # default-sheet swap, so without it existing windows would never invalidate.
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
