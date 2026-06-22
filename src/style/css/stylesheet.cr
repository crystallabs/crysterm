module Crysterm
  module CSS
    # A single parsed CSS rule: one selector paired with its declaration block.
    #
    # A comma-separated selector list in the source becomes one `Rule` per
    # selector, so each carries its own specificity and (peeled) state.
    struct Rule
      # The *structural* selector handed to the `html5` matcher — i.e. the
      # source selector with any state pseudo-class (`:focus`, ...) removed.
      getter selector : String

      # Property => value, with property names lower-cased.
      getter declarations : Hash(String, String)

      # The widget state this rule applies to, peeled from a trailing
      # pseudo-class. `nil` means the rule has no state pseudo-class and so
      # applies in *every* state (a base rule).
      getter state : WidgetState?

      # CSS specificity as `{ids, classes+attrs+pseudos, types}`, compared
      # lexicographically; computed from the *original* selector so a
      # `:focus` rule outranks its base.
      getter specificity : Tuple(Int32, Int32, Int32)

      # Source order; breaks specificity ties (later wins).
      getter order : Int32

      def initialize(@selector, @declarations, @state, @specificity, @order)
      end
    end

    # An ordered collection of `Rule`s parsed from CSS text.
    class Stylesheet
      getter rules : Array(Rule)

      def initialize(@rules = [] of Rule)
      end

      # Maps a state pseudo-class to a `WidgetState`. `:active` and `:selected`
      # are treated as synonyms, as are `:blur`/`:blurred`.
      STATE_PSEUDOS = {
        ":focus"    => WidgetState::Focused,
        ":hover"    => WidgetState::Hovered,
        ":selected" => WidgetState::Selected,
        ":active"   => WidgetState::Selected,
        ":disabled" => WidgetState::Disabled,
        ":blurred"  => WidgetState::Blurred,
        ":blur"     => WidgetState::Blurred,
        ":normal"   => WidgetState::Normal,
      }

      # Parses a CSS string into a `Stylesheet`.
      #
      # Supports comments, comma-separated selector lists, and `prop: value;`
      # declaration blocks. State pseudo-classes are peeled onto the rule (see
      # `Rule#state`); the structural remainder is what the selector engine
      # matches. There is intentionally no `@media`/nesting support yet.
      def self.parse(css : String) : Stylesheet
        rules = [] of Rule
        order = 0

        decommented(css).split('}').each do |chunk|
          next unless chunk.includes?('{')
          prelude, _, body = chunk.partition('{')
          declarations = parse_declarations(body)
          next if declarations.empty?

          prelude.split(',').each do |raw|
            selector = raw.strip
            next if selector.empty?
            # Specificity is computed from the *original* selector (so a type
            # selector counts as a type), then types are rewritten to classes
            # for matching against the class-based document.
            spec = Specificity.calculate(selector)
            state, structural = peel_state(selector)
            rules << Rule.new(Selectors.expand_types(structural), declarations, state, spec, order)
            order += 1
          end
        end

        new rules
      end

      # Strips `/* ... */` comments (including multi-line).
      private def self.decommented(css : String) : String
        css.gsub(/\/\*.*?\*\//m, " ")
      end

      # Parses a declaration block body (`prop: val; prop2: val2`) into a hash.
      private def self.parse_declarations(body : String) : Hash(String, String)
        decls = {} of String => String
        body.split(';').each do |part|
          next unless part.includes?(':')
          name, _, value = part.partition(':')
          name = name.strip.downcase
          value = value.strip
          decls[name] = value unless name.empty? || value.empty?
        end
        decls
      end

      # State pseudo-class tokens, longest first, so a longer token is matched
      # before any shorter token it contains as a substring (e.g. `:blurred`
      # before `:blur`).
      STATE_PSEUDOS_BY_LENGTH = STATE_PSEUDOS.to_a.sort_by! { |(token, _)| -token.size }

      # Splits a state pseudo-class off a selector, returning `{state,
      # structural_selector}`. Only the first recognized pseudo-class is peeled
      # (Phase 1 supports a single, subject-anchored state pseudo per selector).
      private def self.peel_state(selector : String) : Tuple(WidgetState?, String)
        STATE_PSEUDOS_BY_LENGTH.each do |(token, state)|
          if selector.includes?(token)
            structural = selector.gsub(token, "").strip
            structural = "*" if structural.empty?
            return {state, structural}
          end
        end
        {nil, selector}
      end
    end
  end
end
