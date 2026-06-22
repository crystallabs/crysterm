module Crysterm
  module CSS
    # A parsed `@media` condition: a conjunction of feature tests evaluated
    # against the terminal's size (and color depth). Only the responsive
    # width/height features plus `min-colors`/`max-colors` are supported.
    struct MediaQuery
      getter conditions : Array(Tuple(String, Int32))

      def initialize(@conditions)
      end

      # Matches `(feature: value)` pairs, e.g. `(min-width: 80)`.
      FEATURE_RE = /\(\s*([a-z-]+)\s*:\s*(\d+)\s*\)/

      # Parses a condition string such as `(min-width: 80) and (max-width: 120)`.
      def self.parse(condition : String) : MediaQuery
        conditions = [] of Tuple(String, Int32)
        condition.scan(FEATURE_RE) do |match|
          conditions << {match[1], match[2].to_i}
        end
        new conditions
      end

      # Whether this query matches a terminal of *width*×*height* cells with
      # *colors* available.
      def matches?(width : Int32, height : Int32, colors : Int32) : Bool
        conditions.all? do |(feature, value)|
          case feature
          when "min-width"  then width >= value
          when "max-width"  then width <= value
          when "min-height" then height >= value
          when "max-height" then height <= value
          when "min-colors" then colors >= value
          when "max-colors" then colors <= value
          else                   true
          end
        end
      end
    end

    # A single parsed CSS rule: one selector paired with its declaration block.
    #
    # A comma-separated selector list in the source becomes one `Rule` per
    # selector, so each carries its own specificity and (peeled) state.
    struct Rule
      # The *structural* selector handed to the `html5` matcher — i.e. the
      # source selector with any state pseudo-class (`:focus`, ...) removed.
      getter selector : String

      # Normal (non-`!important`) declarations: property => value, property
      # names lower-cased.
      getter declarations : Hash(String, String)

      # Declarations flagged `!important`; these outrank everything else in the
      # cascade (see `Cascade`).
      getter important : Hash(String, String)

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

      # The `@media` condition guarding this rule, or `nil` if unconditional.
      getter media : MediaQuery?

      def initialize(@selector, @declarations, @important, @state, @specificity, @order, @media = nil)
      end
    end

    # An ordered collection of `Rule`s parsed from CSS text.
    class Stylesheet
      getter rules : Array(Rule)

      # Custom properties (`--name: value`) collected globally, last definition
      # winning. Resolved into `var(--name[, fallback])` references at cascade
      # time. (A pragmatic, document-global model — not per-element cascaded.)
      getter variables : Hash(String, String)

      # Non-fatal diagnostics gathered while parsing — malformed declarations and
      # unknown property names. Parsing never raises; inspect this to surface
      # problems (e.g. `screen.css_stylesheet.try &.warnings`).
      getter warnings : Array(String)

      # Whether any rule depends on a widget's *state* via an ancestor-state
      # pseudo-class (e.g. `Form:focus Button`), lowered to a `.state-*` class.
      # Such rules must be re-evaluated when states change, so the cascade is
      # invalidated on state transitions only when this is set.
      @dynamic_state : Bool = false

      def initialize(@rules = [] of Rule, @variables = {} of String => String, @warnings = [] of String)
        @dynamic_state = @rules.any?(&.selector.includes?(".state-"))
      end

      # :ditto:
      def dynamic_state? : Bool
        @dynamic_state
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
      # Supports comments, comma-separated selector lists, `prop: value;`
      # declaration blocks, `!important`, custom properties/`var()`, and
      # `@media` blocks. State pseudo-classes are peeled onto the rule (see
      # `Rule#state`); the structural remainder is what the selector engine
      # matches.
      def self.parse(css : String) : Stylesheet
        rules = [] of Rule
        variables = {} of String => String
        warnings = [] of String

        decommented = decommented(css)
        top_level, media_blocks = extract_media(decommented)

        order = parse_block(top_level, nil, rules, variables, warnings, 0)
        media_blocks.each do |(condition, inner)|
          order = parse_block(inner, MediaQuery.parse(condition), rules, variables, warnings, order)
        end

        new rules, variables, warnings
      end

      # Parses one block of rules (a top-level body or an `@media` block's
      # contents), tagging each rule with *media*. Appends to *rules*, collects
      # custom properties into *variables* and diagnostics into *warnings*, and
      # returns the next source order.
      private def self.parse_block(css : String, media : MediaQuery?, rules : Array(Rule), variables : Hash(String, String), warnings : Array(String), order : Int32) : Int32
        css.split('}').each do |chunk|
          next unless chunk.includes?('{')
          prelude, _, body = chunk.partition('{')
          declarations, important = parse_declarations(body, variables, warnings)
          next if declarations.empty? && important.empty?

          prelude.split(',').each do |raw|
            selector = raw.strip
            next if selector.empty?
            # Specificity is computed from the *original* selector (so a type
            # selector counts as a type). The selector is then split into its
            # subject (rightmost compound) and the ancestor prefix: a state
            # pseudo on the subject becomes the rule's own state, while state
            # pseudos on ancestors are lowered to `.state-*` classes matched
            # against the live document. Finally types are rewritten to classes.
            spec = Specificity.calculate(selector)
            prefix, subject = split_subject(selector)
            state, subject = peel_state(subject)
            structural = Selectors.expand_types(rewrite_ancestor_states(prefix) + subject)
            rules << Rule.new(structural, declarations, important, state, spec, order, media)
            order += 1
          end
        end
        order
      end

      # Splits `@media <condition> { ... }` blocks out of *css*, returning the
      # remaining top-level CSS and a list of `{condition, inner_css}`. Brace
      # nesting is honored so the `@media` body is captured whole.
      private def self.extract_media(css : String) : Tuple(String, Array(Tuple(String, String)))
        blocks = [] of Tuple(String, String)
        remaining = String::Builder.new
        i = 0
        n = css.size
        while i < n
          if css[i] == '@' && css[i, 6]? == "@media"
            brace = css.index('{', i)
            break unless brace
            condition = css[i + 6...brace].strip
            depth = 0
            j = brace
            while j < n
              depth += 1 if css[j] == '{'
              if css[j] == '}'
                depth -= 1
                break if depth == 0
              end
              j += 1
            end
            blocks << {condition, css[brace + 1...j]}
            i = j + 1
          else
            remaining << css[i]
            i += 1
          end
        end
        {remaining.to_s, blocks}
      end

      # Matches a `var(--name)` or `var(--name, fallback)` reference.
      VAR_RE = /var\(\s*(--[A-Za-z0-9_-]+)\s*(?:,([^)]*))?\)/

      # Resolves `var(...)` references in *value* against *variables*, falling
      # back to the in-call fallback (or empty) for undefined names. Iterates a
      # few times so a variable whose value itself uses `var()` resolves too.
      def self.resolve_var(value : String, variables : Hash(String, String)) : String
        return value unless value.includes?("var(")
        result = value
        4.times do
          replaced = result.gsub(VAR_RE) do |_match|
            md = $~
            name = md[1]
            if defined = variables[name]?
              defined
            elsif fallback = md[2]?
              fallback.strip
            else
              ""
            end
          end
          break if replaced == result
          result = replaced
        end
        result
      end

      # Strips `/* ... */` comments (including multi-line).
      private def self.decommented(css : String) : String
        css.gsub(/\/\*.*?\*\//m, " ")
      end

      # Parses a declaration block body into `{normal, important}` hashes.
      # Custom properties (`--name`) are siphoned into *variables* (their names
      # are case-sensitive and so kept as-is); other property names are
      # lower-cased. A trailing `!important` routes a declaration to the
      # important hash.
      private def self.parse_declarations(body : String, variables : Hash(String, String), warnings : Array(String)) : Tuple(Hash(String, String), Hash(String, String))
        normal = {} of String => String
        important = {} of String => String
        body.split(';').each do |part|
          stripped = part.strip
          next if stripped.empty?
          unless part.includes?(':')
            warnings << "malformed declaration (missing ':'): #{stripped.inspect}"
            next
          end

          name, _, value = part.partition(':')
          name = name.strip
          value = value.strip
          if name.empty? || value.empty?
            warnings << "malformed declaration: #{stripped.inspect}"
            next
          end

          if name.starts_with?("--")
            variables[name] = value # custom property (case-sensitive name)
            next
          end

          name = name.downcase
          warnings << "unknown property: #{name.inspect}" unless Properties.known?(name)
          if value.downcase.ends_with?("!important")
            important[name] = value[0...value.size - "!important".size].rstrip
          else
            normal[name] = value
          end
        end
        {normal, important}
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

      # Splits a selector into `{prefix, subject}`, where *subject* is the
      # rightmost compound (after the last top-level combinator) and *prefix* is
      # everything up to and including that combinator (so `prefix + subject`
      # reconstructs the selector). Combinators inside `[...]`/`(...)` are
      # ignored.
      private def self.split_subject(selector : String) : Tuple(String, String)
        depth = 0
        cut = -1
        selector.each_char_with_index do |char, idx|
          case char
          when '[', '(' then depth += 1
          when ']', ')' then depth -= 1
          when ' ', '>', '+', '~'
            cut = idx + 1 if depth == 0
          end
        end
        return {"", selector} if cut < 0
        {selector[0...cut], selector[cut..].strip}
      end

      # Rewrites state pseudo-classes appearing on *ancestor* compounds into
      # `.state-*` classes (e.g. `Form:focus ` -> `Form.state-focused `), so they
      # match against the live document's stamped state classes. Longest token
      # first to avoid the `:blurred`/`:blur` substring trap.
      private def self.rewrite_ancestor_states(prefix : String) : String
        result = prefix
        STATE_PSEUDOS_BY_LENGTH.each do |(token, state)|
          result = result.gsub(token, ".state-#{state.to_s.downcase}") if result.includes?(token)
        end
        result
      end
    end
  end
end
