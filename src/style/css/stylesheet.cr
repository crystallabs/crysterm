module Crysterm
  module CSS
    # A parsed `@media` condition: a conjunction of feature tests evaluated
    # against the terminal's size and color depth. Only width/height and
    # `min-colors`/`max-colors` features are supported.
    struct MediaQuery
      getter conditions : Array(Tuple(String, Int32))

      def initialize(@conditions)
      end

      # Matches `(feature: value)` pairs, e.g. `(min-width: 80)`. A trailing unit
      # (`px`, `em`, `%`, …) is tolerated and ignored: crysterm features are in
      # cell counts, but authors porting CSS habits write `(max-width: 40px)`.
      # Requiring a bare integer made a unit'd feature fail to match, so it was
      # dropped from `conditions`; if it was the only feature, the now-empty
      # conjunction (`[].all?` is `true`) matched *every* terminal — the opposite
      # of the intent. Swallowing the unit keeps the query meaningful.
      FEATURE_RE = /\(\s*([a-z-]+)\s*:\s*(\d+)[a-z%]*\s*\)/

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
      # The *structural* selector handed to the `html5` matcher — the source
      # selector with any state pseudo-class (`:focus`, ...) removed.
      getter selector : String

      # Normal (non-`!important`) declarations: property => value, property
      # names lower-cased.
      getter declarations : Hash(String, String)

      # Declarations flagged `!important`; outrank everything else in the
      # cascade (see `Cascade`).
      getter important : Hash(String, String)

      # The widget state this rule applies to, peeled from a trailing
      # pseudo-class. `nil` means the rule applies in *every* state (a base rule).
      getter state : WidgetState?

      # CSS specificity as `{ids, classes+attrs+pseudos, types}`, compared
      # lexicographically; computed from the *original* selector so a
      # `:focus` rule outranks its base.
      getter specificity : Tuple(Int32, Int32, Int32)

      # Source order; breaks specificity ties (later wins).
      getter order : Int32

      # The `@media` condition guarding this rule, or `nil` if unconditional.
      getter media : MediaQuery?

      # A `:has(...)` relational condition on the subject (already type-expanded),
      # or `nil`. Matched nodes are kept only if `node.css(has)` is non-empty.
      # (Implemented here since the `html5` selector engine lacks `:has`.)
      getter has : String?

      # `:has(...)` relational conditions borne by an *ancestor* compound (e.g.
      # `Form:has(.error) Button` — the `:has` is on `Form`, not the subject
      # `Button`), or `nil`. Each entry is `{qualifier, inner}`: *qualifier* is
      # the type-expanded selector for the ancestor up to the has-bearing
      # compound (with `:has(...)` removed), *inner* is the type-expanded
      # relative selector. A matched subject is kept only if it descends from a
      # node matching *qualifier* that has an *inner* descendant.
      getter ancestor_has : Array(Tuple(String, String))?

      # The `@layer` rank this rule belongs to (lower = declared earlier = lower
      # priority). Unlayered rules use `UNLAYERED`, which outranks every layer.
      getter layer_rank : Int32

      def initialize(@selector, @declarations, @important, @state, @specificity, @order, @media = nil, @has = nil, @layer_rank = UNLAYERED, @ancestor_has = nil)
      end
    end

    # Layer rank for rules outside any `@layer`. Larger than any real layer rank
    # so unlayered declarations win over layered ones (per the CSS cascade).
    UNLAYERED = 1_000_000

    # An ordered collection of `Rule`s parsed from CSS text.
    class Stylesheet
      getter rules : Array(Rule)

      # Custom properties (`--name: value`) collected globally, last definition
      # winning. Resolved into `var(--name[, fallback])` references at cascade
      # time. Document-global, not per-element cascaded.
      getter variables : Hash(String, String)

      # Non-fatal diagnostics gathered while parsing — malformed declarations and
      # unknown property names. Parsing never raises; inspect this to surface
      # problems (e.g. `window.css_stylesheet.try &.warnings`).
      getter warnings : Array(String)

      # Parsed `@keyframes`: animation name -> ordered stops `[{offset 0..1,
      # declarations}]`. Consumed by `Widget`'s CSS-animation driver.
      getter keyframes : Hash(String, Array(Tuple(Float64, Hash(String, String))))

      # Whether any rule depends on a widget's *state* via an ancestor-state
      # pseudo-class (e.g. `Form:focus Button`), lowered to a `.state-*` class.
      # The cascade is invalidated on state transitions only when this is set.
      @dynamic_state : Bool = false

      def initialize(@rules = [] of Rule, @variables = {} of String => String, @warnings = [] of String,
                     @keyframes = {} of String => Array(Tuple(Float64, Hash(String, String))))
        @dynamic_state = @rules.any?(&.selector.includes?(".state-"))
      end

      # :ditto:
      def dynamic_state? : Bool
        @dynamic_state
      end

      # Compiled selectors, memoized by their structural string. Compiling once
      # here — rather than letting `Node#css` re-lex/re-compile on each match —
      # avoids repeated parser work. A `nil` entry marks an unparseable selector
      # so it isn't retried.
      @compiled_selectors = {} of String => ::CSS::Selector?

      def compiled_selector(selector : String) : ::CSS::Selector?
        @compiled_selectors.fetch(selector) do
          @compiled_selectors[selector] = (::CSS.compile(selector) rescue nil)
        end
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

      # Standard-CSS state pseudo-classes (Selectors L4) that Crysterm backs with
      # boolean *attributes* rather than `.state-*` classes — `:checked` and
      # `:indeterminate` map to the `[checked]`/`[indeterminate]` attributes
      # emitted by `widget_attributes.cr`, and `:enabled` to `:not(:disabled)`
      # (its inner `:disabled` is then lowered to `.state-disabled`, legal inside
      # `:not()`). Unlike `STATE_PSEUDOS`, these are rewritten textually into
      # every stylesheet (author `.css`, inline, theme, `.qss`), so the idiomatic
      # spelling works natively, not only when translated from Qt by `CSS::Qss`.
      ATTR_PSEUDOS = {
        "checked"       => "[checked]",
        "indeterminate" => "[indeterminate]",
        "enabled"       => ":not(:disabled)",
      }

      # Matches exactly the `ATTR_PSEUDOS` tokens as whole pseudo-classes (the
      # trailing lookahead keeps `:enabled` from biting into a longer identifier).
      ATTR_PSEUDO = /:(checked|indeterminate|enabled)(?![A-Za-z0-9_-])/

      # Matches a `::slot` pseudo-element token (`ProgressBar::indicator`). Lowered
      # to the *capitalized descendant node* Crysterm emits for that slot; see
      # `lower_sub_elements`.
      SUB_ELEMENT_PSEUDO = /::([a-z][a-z-]*)/

      # Mutable state threaded through the recursive parse.
      private class ParseCtx
        getter rules = [] of Rule
        getter variables = {} of String => String
        getter warnings = [] of String
        getter layers = {} of String => Int32
        getter keyframes = {} of String => Array(Tuple(Float64, Hash(String, String)))
        property order = 0
        getter base_path : String?

        def initialize(@base_path = nil)
        end

        # Rank for a named `@layer`, assigned on first appearance (so layers
        # order by declaration order; later layers outrank earlier ones).
        def layer_rank(name : String) : Int32
          layers.fetch(name) { layers[name] = layers.size }
        end
      end

      # Parses a CSS string into a `Stylesheet`. *base_path* (a file or its dir)
      # resolves `@import`.
      #
      # Supports comments, comma-separated selector lists, `prop: value;` blocks,
      # `!important`, custom properties/`var()`, `@media`, `@layer`, `@import`,
      # and native nesting (`A { B { ... } }`, `&`).
      def self.parse(css : String, base_path : String? = nil) : Stylesheet
        ctx = ParseCtx.new(base_path)
        parse_scope(decommented(css), [] of String, nil, UNLAYERED, ctx)
        new ctx.rules, ctx.variables, ctx.warnings, ctx.keyframes
      end

      # Parses a sequence of constructs within one scope. *parents* are the
      # enclosing (already-combined) selectors for native nesting — empty at top
      # level; when non-empty, the scope's direct declarations are emitted as a
      # rule for them.
      #
      private def self.parse_scope(css : String, parents : Array(String), media : MediaQuery?, layer_rank : Int32, ctx : ParseCtx) : Nil
        declarations = {} of String => String
        important = {} of String => String
        pos = 0
        n = css.size
        while pos < n
          pos = skip_ws(css, pos)
          break if pos >= n
          start = pos
          # Read the prelude up to the next top-level `{`/`;`/`}`, skipping
          # parenthesised, bracketed and quoted spans so values like `url(a;b)`
          # and attribute selectors like `[href="a{b}"]` / `[x=a;b]` are safe.
          while pos < n
            ch = css[pos]
            break if ch == '{' || ch == ';' || ch == '}'
            if ch == '('
              pos = skip_balanced(css, pos, '(', ')')
            elsif ch == '['
              pos = skip_balanced(css, pos, '[', ']')
            elsif ch == '"' || ch == '\''
              pos = skip_string(css, pos)
            else
              pos += 1
            end
          end
          # No terminator at end of input: the final construct in a block may
          # omit its trailing `;` (e.g. `{ color: red }`), so flush it as a
          # statement rather than dropping it.
          if pos >= n
            handle_statement(css[start...pos].strip, parents, declarations, important, layer_rank, ctx)
            break
          end
          prelude = css[start...pos].strip
          case css[pos]
          when ';'
            pos += 1
            handle_statement(prelude, parents, declarations, important, layer_rank, ctx)
          when '{'
            close = matching_brace(css, pos)
            body = close ? css[(pos + 1)...close] : css[(pos + 1)..]
            pos = close ? close + 1 : n
            handle_block(prelude, body, parents, media, layer_rank, ctx)
          when '}'
            pos += 1 # stray close brace
          end
        end
        emit_rules(parents, declarations, important, media, layer_rank, ctx) unless parents.empty?
      end

      # A `;`-terminated construct: an at-statement (`@import`, `@layer a, b;`)
      # or, inside a rule body, a declaration.
      private def self.handle_statement(prelude : String, parents : Array(String), declarations, important, layer_rank : Int32, ctx : ParseCtx) : Nil
        return if prelude.empty?
        # At-rule names are case-insensitive (`@IMPORT`/`@Layer`); the slice
        # offsets below are by the fixed name length, so they hold for any casing.
        if Case.at_rule?(prelude, "import")
          handle_import prelude, layer_rank, ctx
        elsif Case.at_rule?(prelude, "layer")
          prelude[6..].split(',').each { |name| ctx.layer_rank(name.strip) unless name.strip.empty? }
        elsif parents.empty?
          ctx.warnings << "stray content at top level: #{prelude.inspect}"
        else
          parse_declaration prelude, declarations, important, ctx
        end
      end

      # A `{ ... }` block: `@media`, `@layer <name>`, or a style rule (which may
      # itself nest further rules).
      private def self.handle_block(prelude : String, body : String, parents : Array(String), media : MediaQuery?, layer_rank : Int32, ctx : ParseCtx) : Nil
        # At-rule names are case-insensitive (`@MEDIA`/`@Keyframes`); the slice
        # offsets below are by the fixed name length, so they hold for any casing.
        if Case.at_rule?(prelude, "keyframes")
          parse_keyframes prelude[10..].strip, body, ctx
        elsif Case.at_rule?(prelude, "media")
          parse_scope body, parents, MediaQuery.parse(prelude[6..].strip), layer_rank, ctx
        elsif Case.at_rule?(prelude, "layer")
          name = prelude[6..].strip
          parse_scope body, parents, media, (name.empty? ? layer_rank : ctx.layer_rank(name)), ctx
        else
          parse_scope body, combine_selectors(parents, prelude), media, layer_rank, ctx
        end
      end

      # Parses an `@keyframes name { 0% { … } 50%,75% { … } to { … } }` block into
      # ordered stops (`from`=0%, `to`=100%), registered under *name*. Each stop's
      # declarations are kept raw and resolved by the animation driver.
      private def self.parse_keyframes(name : String, body : String, ctx : ParseCtx) : Nil
        return if name.empty?
        stops = [] of Tuple(Float64, Hash(String, String))
        pos = 0
        n = body.size
        while pos < n
          pos = skip_ws(body, pos)
          break if pos >= n
          start = pos
          while pos < n && body[pos] != '{'
            pos += 1
          end
          break if pos >= n
          selector = body[start...pos].strip
          close = matching_brace(body, pos)
          decl_text = close ? body[(pos + 1)...close] : body[(pos + 1)..]
          pos = close ? close + 1 : n
          decls = {} of String => String
          ignore = {} of String => String
          decl_text.split(';').each do |d|
            d = d.strip
            parse_declaration(d, decls, ignore, ctx) unless d.empty?
          end
          selector.split(',').each do |off|
            keyframe_offset(off.strip).try { |o| stops << {o, decls} }
          end
        end
        ctx.keyframes[name] = stops.sort_by!(&.[0]) unless stops.empty?
      end

      # `from`=0, `to`=1, `NN%`=NN/100.
      private def self.keyframe_offset(s : String) : Float64?
        case s
        when "from" then 0.0
        when "to"   then 1.0
        else
          s.ends_with?('%') ? s[0...-1].to_f?.try(&./(100.0)) : nil
        end
      end

      # Combines *parents* with the comma-separated *child* selector list per CSS
      # nesting: `&` is replaced by the parent, otherwise the child becomes a
      # descendant of it.
      private def self.combine_selectors(parents : Array(String), child : String) : Array(String)
        children = child.split(',').map(&.strip).reject(&.empty?)
        return children if parents.empty?
        combined = [] of String
        parents.each do |parent|
          children.each do |part|
            combined << (part.includes?('&') ? part.gsub('&', parent) : "#{parent} #{part}")
          end
        end
        combined
      end

      # Emits one `Rule` per selector with the scope's collected declarations.
      private def self.emit_rules(selectors : Array(String), declarations, important, media : MediaQuery?, layer_rank : Int32, ctx : ParseCtx) : Nil
        return if declarations.empty? && important.empty?
        selectors.each do |selector|
          next if selector.empty?
          # First lower the idiomatic Qt-ish spellings to Crysterm's internal
          # forms: `::slot` pseudo-elements to capitalized descendant nodes, and
          # the standard attribute-backed pseudos (`:checked` -> `[checked]`,
          # `:enabled` -> `:not(:disabled)`). Everything below — specificity,
          # peeling, the `.state-*` lowering of the resulting `:not(:disabled)`,
          # `expand_types` — then operates on the form actually matched.
          selector = lower_sub_elements(selector)
          selector = lower_attr_pseudos(selector)
          # Specificity is from the attr-lowered selector; then the subject's
          # state pseudo / `:has` are peeled, ancestor state pseudos lowered, and
          # types rewritten to classes — per combined selector.
          spec = Specificity.calculate(selector)
          prefix, subject = split_subject(selector)
          state, subject = peel_state(subject)
          has, subject = peel_has(subject)
          # `:has(...)` borne by an ancestor compound (`Form:has(.error) Button`)
          # is peeled separately: the engine can't parse `:has`, so it's stripped
          # from the structural prefix and evaluated relationally in the cascade.
          ancestor_has, prefix = peel_ancestor_has(prefix)
          # Lower remaining state pseudos — ancestor ones in the prefix and any
          # nested in the subject (e.g. `:not(:focus)`) — to `.state-*` classes
          # matching the document's stamped state. The subject's own top-level
          # state was already peeled above and carried on the rule.
          structural = Selectors.expand_types(lower_state_pseudos(prefix + subject))
          ctx.rules << Rule.new(structural, declarations, important, state, spec, ctx.order, media, has, layer_rank, ancestor_has)
          ctx.order += 1
        end
      end

      # Loads `@import "file";` (or `@import url(file);`) relative to the base
      # path and parses it inline, so its rules precede — and are overridden
      # by — the importing file's.
      private def self.handle_import(prelude : String, layer_rank : Int32, ctx : ParseCtx) : Nil
        path = prelude[/@import\s+(?:url\()?["']?([^"')]+)["']?\)?/i, 1]?
        return unless path
        base = ctx.base_path
        resolved = base ? File.expand_path(path, File.directory?(base) ? base : File.dirname(base)) : path
        content = begin
          File.read(resolved)
        rescue
          ctx.warnings << "@import: cannot read #{resolved.inspect}"
          return
        end
        parse_scope decommented(content), [] of String, nil, layer_rank, ctx
      end

      private def self.skip_ws(css : String, pos : Int32) : Int32
        while pos < css.size && css[pos].whitespace?
          pos += 1
        end
        pos
      end

      private def self.skip_string(css : String, i : Int32) : Int32
        quote = css[i]
        i += 1
        while i < css.size
          ch = css[i]
          return i + 1 if ch == quote
          i += 1 if ch == '\\'
          i += 1
        end
        i
      end

      # Advances past a region opened at *i* (an *open* char) to just after its
      # matching *close*, honoring nesting and quotes.
      private def self.skip_balanced(css : String, i : Int32, open : Char, close : Char) : Int32
        depth = 0
        while i < css.size
          ch = css[i]
          if ch == '"' || ch == '\''
            i = skip_string(css, i)
            next
          elsif ch == open
            depth += 1
          elsif ch == close
            depth -= 1
            return i + 1 if depth == 0
          end
          i += 1
        end
        i
      end

      # Index of the `}` matching the `{` at *open*, or `nil` if unbalanced.
      private def self.matching_brace(css : String, open : Int32) : Int32?
        index = skip_balanced(css, open, '{', '}')
        index > open && css[index - 1]? == '}' ? index - 1 : nil
      end

      # Resolves `var(...)` references in *value* against *variables*, falling
      # back to the in-call fallback (or empty) for undefined names. Iterates a
      # few times so a variable whose value itself uses `var()` resolves too.
      def self.resolve_var(value : String, variables : Hash(String, String)) : String
        # `var(` is a case-insensitive CSS function name (`VAR(--x)`); the
        # custom-property name inside it stays case-sensitive (see `Case::VAR_CALL`).
        return value unless value.matches?(Case::VAR_CALL)
        result = value
        4.times do
          replaced = replace_vars(result, variables)
          break if replaced == result
          result = replaced
        end
        result
      end

      # Replaces every `var(--name[, fallback])` reference in *value* in a single
      # left-to-right pass, matching each call's balanced closing paren so a
      # nested `var()` in the fallback (`var(--a, var(--b, red))`) is consumed as
      # one unit — a `[^)]*` regex would stop at the first `)`, leaving a stray
      # `)` once the outer name resolves. A defined name takes its value and
      # drops the fallback; an undefined one falls back (possibly itself a
      # `var()`, resolved on the next `resolve_var` iteration), else empty.
      private def self.replace_vars(value : String, variables : Hash(String, String)) : String
        idx = value.index(Case::VAR_CALL)
        return value unless idx
        open = idx + 3 # index of the '('
        close = matching_paren(value, open)
        return value unless close
        inner = value[(open + 1)...close]
        comma = top_level_comma(inner)
        name = (comma ? inner[0...comma] : inner).strip
        fallback = comma ? inner[(comma + 1)..].strip : nil
        replacement = if defined = variables[name]?
                        defined
                      elsif fallback
                        fallback
                      else
                        ""
                      end
        value[0...idx] + replacement + replace_vars(value[(close + 1)..], variables)
      end

      # Index of the first top-level (paren-depth-0) comma in *value*, or `nil` —
      # the separator between a `var()`'s name and its fallback, skipping commas
      # inside a nested function's parens.
      private def self.top_level_comma(value : String) : Int32?
        depth = 0
        value.each_char_with_index do |ch, i|
          case ch
          when '(' then depth += 1
          when ')' then depth -= 1
          when ',' then return i if depth == 0
          end
        end
        nil
      end

      # Parses a stylesheet from a `.css` file (its path is used to resolve
      # `@import`).
      def self.from_file(path : String | Path) : Stylesheet
        source = File.read(path)
        # `.qss` (Qt Style Sheet) files are translated to Crysterm CSS first —
        # strip the `Q` selector prefix and rename Qt classes to ours; see
        # `CSS::Qss`. Unmapped selectors fall through to the tolerant parser.
        source = Qss.to_css(source) if path.to_s.downcase.ends_with?(".qss")
        parse source, base_path: path.to_s
      end

      # Strips `/* ... */` comments (including multi-line).
      private def self.decommented(css : String) : String
        css.gsub(/\/\*.*?\*\//m, " ")
      end

      # Parses a single `prop: value` declaration into *declarations*/*important*
      # (or *variables* for a `--custom` property). Custom-property names are
      # case-sensitive; other names are lower-cased. A trailing `!important`
      # routes the declaration to the important hash.
      private def self.parse_declaration(text : String, declarations : Hash(String, String), important : Hash(String, String), ctx : ParseCtx) : Nil
        unless text.includes?(':')
          ctx.warnings << "malformed declaration (missing ':'): #{text.inspect}"
          return
        end
        name, _, value = text.partition(':')
        name = name.strip
        value = value.strip
        if name.empty? || value.empty?
          ctx.warnings << "malformed declaration: #{text.inspect}"
          return
        end
        if name.starts_with?("--")
          ctx.variables[name] = value # custom property, case-sensitive name
          return
        end
        name = name.downcase
        ctx.warnings << "unknown property: #{name.inspect}" unless Properties.known?(name)
        if value.downcase.ends_with?("!important")
          important[name] = value[0...value.size - "!important".size].rstrip
        else
          declarations[name] = value
        end
      end

      # State pseudo-class tokens, longest first, so a longer token is matched
      # before any shorter token it contains as a substring (e.g. `:blurred`
      # before `:blur`).
      STATE_PSEUDOS_BY_LENGTH = STATE_PSEUDOS.to_a.sort_by! { |(token, _)| -token.size }

      # Precompiled matchers for `lower_state_pseudos`, one per state pseudo
      # (longest token first). Each pairs a boundary-anchored regex — leading
      # `:` bounds the start, negative lookahead forbids a trailing identifier
      # char so `:focus` can't match inside `:focus-within` — with the
      # `.state-*` class it lowers to. Built once: compiling a regex per
      # selector at parse time would be wasteful.
      STATE_PSEUDO_MATCHERS = STATE_PSEUDOS_BY_LENGTH.map do |(token, state)|
        # Pseudo-class names are case-insensitive (`:HOVER` == `:hover`); the
        # matcher rewrites only the `:state` token, leaving the rest of the
        # selector (type names etc.) and its casing untouched.
        {Regex.new(Regex.escape(token) + "(?![A-Za-z0-9_-])", Regex::Options::IGNORE_CASE), ".#{state.css_class}"}
      end

      # Splits a state pseudo-class off a selector, returning `{state,
      # structural_selector}`. Only a top-level pseudo (outside any `[...]`
      # attribute value or `(...)` functional-pseudo argument) that stands as a
      # complete token — not a prefix of a longer pseudo such as
      # `:focus-within` — is treated as the subject's state; nested ones are
      # left for `lower_state_pseudos`. Only the first recognized pseudo-class
      # is peeled (a single subject-anchored state pseudo per selector).
      private def self.peel_state(selector : String) : Tuple(WidgetState?, String)
        return {nil, selector} unless selector.includes?(':') # fast path: no pseudo at all
        STATE_PSEUDOS_BY_LENGTH.each do |(token, state)|
          if idx = top_level_pseudo_index(selector, token)
            structural = (selector[0...idx] + selector[(idx + token.size)..]).strip
            structural = "*" if structural.empty?
            return {state, structural}
          end
        end
        {nil, selector}
      end

      # Index of the first occurrence of *token* in *selector* that is at the top
      # level (depth 0 w.r.t. `[]`/`()`) and bounded as a complete pseudo-class
      # (following char, if any, is not an identifier char, so `:focus` never
      # matches inside `:focus-within`), or `nil`.
      private def self.top_level_pseudo_index(selector : String, token : String) : Int32?
        depth = 0
        last = selector.size - token.size
        i = 0
        while i <= last
          case selector[i]
          when '[', '(' then depth += 1
          when ']', ')' then depth -= 1
          else
            # Pseudo-class names are case-insensitive (`:HOVER` == `:hover`), so
            # compare the token span case-insensitively; the rest of the
            # selector (type names, ids, classes) stays case-sensitive.
            if depth == 0 && selector[i, token.size].compare(token, case_insensitive: true) == 0 && !ident_char?(selector[i + token.size]?)
              return i
            end
          end
          i += 1
        end
        nil
      end

      # Whether *char* can appear inside a CSS identifier (so a state token
      # followed by one is really part of a longer pseudo-class). `nil` (end of
      # string) is a boundary, not an identifier char.
      private def self.ident_char?(char : Char?) : Bool
        char ? Selectors.ident?(char) : false
      end

      # Splits a selector into `{prefix, subject}`, where *subject* is the
      # rightmost compound (after the last top-level combinator) and *prefix* is
      # everything up to and including that combinator (so `prefix + subject`
      # reconstructs the selector). Combinators inside `[...]`/`(...)` are ignored.
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

      # The `:has(...)` inner (relative) selector carried between *open* (the
      # `(`) and *close* (the `)`) in *source*: the trimmed body, anchored at
      # `:scope` when it leads with a combinator (`> .x` / `+ .x` / `~ .x`) so
      # the relational match is rooted at the subject. Shared by `peel_has` and
      # `peel_ancestor_has`.
      private def self.has_inner(source : String, open : Int32, close : Int32) : String
        inner = source[(open + 1)...close].strip
        inner.starts_with?('>') || inner.starts_with?('+') || inner.starts_with?('~') ? ":scope #{inner}" : inner
      end

      # Splits a `:has(...)` relational pseudo-class off the (subject) selector,
      # returning `{inner_selector, remaining}`. The inner selector is
      # type-expanded for matching against a node's subtree; a leading
      # combinator (`> .x`) is anchored with `:scope`. Only the first `:has` is
      # handled; the `html5` engine has no `:has`, so the cascade evaluates it.
      private def self.peel_has(selector : String) : Tuple(String?, String)
        idx = selector.index(":has(")
        return {nil, selector} unless idx
        open = idx + 4 # index of '('
        close = matching_paren(selector, open)
        return {nil, selector} unless close

        inner = has_inner(selector, open, close)
        remaining = (selector[0...idx] + selector[(close + 1)..]).strip
        remaining = "*" if remaining.empty?
        {Selectors.expand_types(inner), remaining}
      end

      # Peels every `:has(...)` borne by an *ancestor* compound out of *prefix*
      # (the part of the selector before the subject), returning
      # `{conditions, prefix_without_has}`. Each condition is
      # `{qualifier, inner}` — see `Rule#ancestor_has`. The structural prefix
      # has all `:has(...)` stripped (the `html5` engine can't parse it); it's
      # re-applied relationally in the cascade.
      private def self.peel_ancestor_has(prefix : String) : Tuple(Array(Tuple(String, String))?, String)
        return {nil, prefix} unless prefix.includes?(":has(")
        conditions = [] of Tuple(String, String)
        search = 0
        while idx = prefix.index(":has(", search)
          open = idx + 4 # index of '('
          close = matching_paren(prefix, open)
          break unless close
          inner = has_inner(prefix, open, close)
          # The qualifier matches the ancestor: everything up to the end of the
          # compound bearing this `:has`, with `:has(...)` removed and types
          # lowered as the structural selector is.
          compound_end = compound_end_index(prefix, close + 1)
          qualifier = Selectors.expand_types(lower_state_pseudos(strip_has(prefix[0...compound_end]))).strip
          conditions << {qualifier, Selectors.expand_types(inner)} unless qualifier.empty?
          search = close + 1
        end
        {conditions.empty? ? nil : conditions, strip_has(prefix)}
      end

      # Index of the end of the compound that begins at/contains *from* — the
      # first top-level combinator (space/`>`/`+`/`~`) at or after *from*, or the
      # end of *selector*. Combinators inside `[...]`/`(...)` are ignored.
      private def self.compound_end_index(selector : String, from : Int32) : Int32
        depth = 0
        i = from
        while i < selector.size
          case selector[i]
          when '[', '(' then depth += 1
          when ']', ')' then depth -= 1
          when ' ', '>', '+', '~'
            return i if depth == 0
          end
          i += 1
        end
        selector.size
      end

      # Removes every `:has(...)` span from *selector* (the `html5` engine can't
      # parse `:has`; it's evaluated relationally in the cascade instead).
      private def self.strip_has(selector : String) : String
        result = selector
        while idx = result.index(":has(")
          open = idx + 4
          close = matching_paren(result, open)
          break unless close
          result = result[0...idx] + result[(close + 1)..]
        end
        result
      end

      # Index of the `)` matching the `(` at *open*, honoring nesting; `nil` if
      # unbalanced.
      private def self.matching_paren(selector : String, open : Int32) : Int32?
        depth = 0
        (open...selector.size).each do |i|
          case selector[i]
          when '(' then depth += 1
          when ')'
            depth -= 1
            return i if depth == 0
          end
        end
        nil
      end

      # Lowers state pseudo-classes still present in *selector* (ancestor ones in
      # the prefix, and any nested in the subject like `:not(:focus)`) into
      # `.state-*` classes (e.g. `Form:focus ` -> `Form.state-focused `), so they
      # match against the live document's stamped state classes. Each token is
      # matched only as a complete pseudo-class, so `:focus` is not torn out of
      # `:focus-within` nor `:blur` out of `:blurred`.
      private def self.lower_state_pseudos(selector : String) : String
        return selector unless selector.includes?(':') # fast path: no pseudo at all
        result = selector
        STATE_PSEUDO_MATCHERS.each { |(re, repl)| result = result.gsub(re, repl) }
        result
      end

      # Rewrites the standard-CSS `:checked`/`:indeterminate`/`:enabled`
      # pseudo-classes into the attribute/`:not()` forms Crysterm matches against
      # (see `ATTR_PSEUDOS`). Applied to the whole selector up front in
      # `emit_rules`, before specificity/state peeling, so the rewrite is uniform
      # across prefix and subject and specificity is computed on the form
      # actually matched — an attribute and a pseudo-class weigh the same.
      private def self.lower_attr_pseudos(selector : String) : String
        return selector unless selector.includes?(':') # fast path: no pseudo at all
        selector.gsub(ATTR_PSEUDO) { ATTR_PSEUDOS[$1] }
      end

      # Rewrites `Type::slot` pseudo-elements into the capitalized descendant node
      # Crysterm matches a slot by (`ProgressBar::indicator` -> `ProgressBar
      # Indicator`, which `expand_types` turns into the `.Indicator` class on the
      # slot node — see `html.cr`/`sub_elements.cr`). Lets the conventional
      # `::slot` spelling work in every stylesheet, not only via `CSS::Qss`. A
      # `::name` with no backing slot becomes a class matching nothing
      # (tolerant). Run before `expand_types`, which otherwise keeps `::name`
      # verbatim as an inert pseudo-element.
      private def self.lower_sub_elements(selector : String) : String
        return selector unless selector.includes?("::")
        selector.gsub(SUB_ELEMENT_PSEUDO) { " #{$1.capitalize}" }
      end
    end
  end
end
