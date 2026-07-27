module Crysterm
  module CSS
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

      # Declarations flagged `!important`; outrank everything else in the cascade.
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
      # Implemented here since the `html5` selector engine lacks `:has`.
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
  end
end
