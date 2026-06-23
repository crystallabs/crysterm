module Crysterm
  module DOM
    # Initializer arg names owned by the base handler, or structural /
    # interaction flags that aren't serializable layout content — skipped by the
    # automatic scan below.
    BASE_KEYS = %w[
      left top right bottom width height name content parse_tags wrap_content
      align overflow style styles visible scrollable input focused children
      index resizable fixed draggable keys vi mouse layout layout_hint
      scrollbar track always_scroll focus_on_click hover_text label parent screen
    ]
  end
end

# Automatic per-widget option (de)serialization — no opt-in required.
#
# Every `Crysterm::Widget` subclass is serializable by virtue of its namespace
# (see `dom_loader.cr` for the matching auto-registration). This generates each
# widget's `#dom_attributes` / `#dom_apply` by scanning its **initializer
# arguments**: every arg whose backing instance variable is exactly a supported
# type — `Bool`, `String`, `Int32`, the `Int32 | String | Nil` dimension union,
# or their nilable forms — is emitted and loaded automatically.
#
# Mechanics:
#  * Generated once per *direct subclass of `Widget`* (the root of each branch);
#    the whole subtree inherits the methods, and because the scan body is wrapped
#    in `{% verbatim %}` it re-resolves per *concrete* widget at instantiation
#    (where `@type` is that widget and `#instance_vars` is available — the
#    `JSON::Serializable` mechanism). The base `Widget` keeps its hand-curated
#    handler for the universal options, reached via `super`.
#  * The scan walks `[@type] + @type.ancestors`, so a widget also serializes
#    options it inherits; `BASE_KEYS` excludes the universal/structural ones.
#  * Types are matched precisely via `union_types` (so e.g. `Array(String)` or an
#    enum is left alone, not mistaken for `String`).
#  * A widget that hand-writes its own `#dom_attributes`/`#dom_apply` (e.g.
#    `List`) is skipped here — that opts it out.
#
# The collection logic is duplicated in both methods because it must live inside
# each `verbatim` block (which can't see outer macro state, and a macro can't
# return a value for `{% for %}`). The round-trip invariant spec exercises every
# registered widget, so the two staying in sync is enforced.
macro finished
  {% for t in Crysterm::Widget.all_subclasses %}
    {% if t.superclass && t.superclass.stringify == "Crysterm::Widget" &&
            !t.methods.any? { |m| m.name == "dom_attributes" || m.name == "dom_apply" } %}
      class ::{{ t }}
        def dom_attributes : ::Hash(::String, ::String?)
          attrs = super
          {% verbatim do %}
            {% begin %}
              {% supported = {} of Nil => Nil %}
              {% for iv in @type.instance_vars %}
                {% nn = iv.type.union_types.map(&.stringify).reject { |x| x == "Nil" } %}
                {% kind = nn == ["Bool"] ? "bool" : (nn == ["Int32"] ? "int" : (nn == ["String"] ? "str" : (nn.sort == ["Int32", "String"] ? "dim" : nil))) %}
                {% supported[iv.name.stringify] = kind if kind %}
              {% end %}
              {% names = [] of Nil %}
              {% for anc in [@type] + @type.ancestors %}
                {% for m in anc.methods.select { |x| x.name == "initialize" } %}
                  {% for a in m.args %}
                    {% n = a.name.stringify %}
                    {% if supported[n] && !::Crysterm::DOM::BASE_KEYS.includes?(n) && !names.includes?(n) %}
                      {% names << n %}
                    {% end %}
                  {% end %}
                {% end %}
              {% end %}
              {% for n in names %}
                {% kind = supported[n] %}{% key = n.split("_").join("-") %}
                {% if kind == "bool" %}
                  attrs[{{ key }}] = "true" if @{{ n.id }}
                {% elsif kind == "str" %}
                  (@{{ n.id }}).try { |s| attrs[{{ key }}] = s unless s.empty? }
                {% else %}
                  (@{{ n.id }}).try { |v| attrs[{{ key }}] = v.to_s }
                {% end %}
              {% end %}
            {% end %}
          {% end %}
          attrs
        end

        def dom_apply(key : ::String, value : ::String?) : ::Bool
          {% verbatim do %}
            {% begin %}
              {% supported = {} of Nil => Nil %}
              {% for iv in @type.instance_vars %}
                {% nn = iv.type.union_types.map(&.stringify).reject { |x| x == "Nil" } %}
                {% kind = nn == ["Bool"] ? "bool" : (nn == ["Int32"] ? "int" : (nn == ["String"] ? "str" : (nn.sort == ["Int32", "String"] ? "dim" : nil))) %}
                {% supported[iv.name.stringify] = {kind, iv.type.union_types.map(&.stringify).includes?("Nil")} if kind %}
              {% end %}
              {% names = [] of Nil %}
              {% for anc in [@type] + @type.ancestors %}
                {% for m in anc.methods.select { |x| x.name == "initialize" } %}
                  {% for a in m.args %}
                    {% n = a.name.stringify %}
                    {% if supported[n] && !::Crysterm::DOM::BASE_KEYS.includes?(n) && !names.includes?(n) %}
                      {% names << n %}
                    {% end %}
                  {% end %}
                {% end %}
              {% end %}
              case key
              {% for n in names %}
                {% kind = supported[n][0] %}{% nilable = supported[n][1] %}{% key = n.split("_").join("-") %}
                when {{ key }}
                  {% if kind == "bool" %}
                    @{{ n.id }} = (value == "true")
                  {% elsif kind == "dim" %}
                    @{{ n.id }} = dom_coerce_dimension(value)
                  {% elsif kind == "int" %}
                    {% if nilable %}
                      @{{ n.id }} = value.try(&.to_i?)
                    {% else %}
                      value.try(&.to_i?).try { |i| @{{ n.id }} = i }
                    {% end %}
                  {% else %} # str
                    @{{ n.id }} = {% if nilable %}value{% else %}value || ""{% end %}
                  {% end %}
              {% end %}
              else
                return super
              end
            {% end %}
          {% end %}
          true
        end
      end
    {% end %}
  {% end %}
end
