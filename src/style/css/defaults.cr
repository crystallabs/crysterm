module Crysterm
  module CSS
    # The default ("user-agent") stylesheet.
    #
    # Applied beneath all author rules (cascade tier `TIER_DEFAULT`) whenever CSS
    # styling is active on a screen, so it provides a baseline that author
    # stylesheets override. It is empty by default — set it once at startup to
    # express widget default looks as CSS:
    #
    # ```
    # Crysterm::CSS.default_stylesheet = <<-CSS
    #   Scrollbar { color: gray; }
    #   Button    { border: solid; }
    # CSS
    # ```
    #
    # Being tier 0, every one of these is overridable by a user `Button { ... }`
    # rule. It only participates when a screen has its own stylesheet set (CSS
    # stays opt-in); with no author stylesheet, nothing is applied.
    @@default_stylesheet = Stylesheet.new

    # The current default stylesheet.
    def self.default_stylesheet : Stylesheet
      @@default_stylesheet
    end

    # Sets the default stylesheet from CSS text.
    def self.default_stylesheet=(css : String) : Stylesheet
      @@default_stylesheet = Stylesheet.parse(css)
    end

    # Sets the default stylesheet from an already-parsed `Stylesheet`.
    def self.default_stylesheet=(sheet : Stylesheet) : Stylesheet
      @@default_stylesheet = sheet
    end
  end
end
