require "./glyphs"
require "../formatting"

module Crysterm
  module Chat
    # Unified-diff formatter for the chat UI: classifies each line of a
    # `diff -u` / `git diff` text and renders it as `{}`-tag-styled content
    # (add/deletion colors from `Glyphs::DEFAULT_CLASS_COLORS` — green/red by
    # default — hunk headers cyan, file headers bold).
    #
    # Model code, not a widget — the widget layer consumes it from both ends:
    # `Widget::Chat::Transcript` diff entries take `.entry_text` (the
    # transcript applies its own `+`/`-` coloring), while tag-parsing widgets
    # (dialogs, previews) take `.format`.
    #
    # Parsing is stateful per hunk: the `@@ -a,b +c,d @@` counts decide how
    # many following lines are hunk body, so a deleted line that itself starts
    # with `--` is never mistaken for a file header.
    module Diff
      # Classification of one diff line.
      enum Kind
        # Hunk-body addition (`+…`).
        Add
        # Hunk-body deletion (`-…`).
        Del
        # Hunk-body context line (unchanged).
        Context
        # Hunk header (`@@ -a,b +c,d @@ …`).
        Hunk
        # File header (`diff …`, `--- a/…`, `+++ b/…`).
        File
        # Binary-content marker (`Binary files … differ`, `GIT binary patch`).
        Binary
        # Anything else: `index …`/mode lines, `\ No newline at end of file`.
        Meta
        # Synthesized `… N unchanged lines` marker replacing context trimmed
        # by `.trim`.
        Elision
      end

      # `@@ -a[,b] +c[,d] @@` — groups 2/4 are the optional old/new line
      # counts (absent count = 1).
      HUNK_HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

      # One classified diff line. `text` is the raw line, newline stripped.
      record Line, kind : Kind, text : String do
        # The chat CSS class for the line: `diff-add`/`diff-del` for
        # additions/deletions, `nil` for everything else.
        def css_class : String?
          case kind
          when .add? then Glyphs::CLASS_DIFF_ADD
          when .del? then Glyphs::CLASS_DIFF_DEL
          end
        end

        # The line as `{}`-tag-styled text (brace-escaped, so diff content
        # can't inject tags). Add/deletion colors resolve through the shared
        # class-color vocabulary (`Glyphs::DEFAULT_CLASS_COLORS`, keyed by
        # `#css_class`); hunk/file decoration is fixed (those kinds carry no
        # styling class).
        def styled : String
          esc = ::Crysterm::Formatting.escape_braces text
          case kind
          in .add?
            color = Glyphs::DEFAULT_CLASS_COLORS[Glyphs::CLASS_DIFF_ADD]
            "{#{color}-fg}#{esc}{/#{color}-fg}"
          in .del?
            color = Glyphs::DEFAULT_CLASS_COLORS[Glyphs::CLASS_DIFF_DEL]
            "{#{color}-fg}#{esc}{/#{color}-fg}"
          in .hunk?
            "{cyan-fg}#{esc}{/cyan-fg}"
          in .file?, .binary?
            "{bold}#{esc}{/bold}"
          in .context?, .meta?, .elision?
            esc
          end
        end
      end

      # Parses *diff* (unified format) into classified lines. Whether a line
      # is hunk body is decided by the header's line counts, not by prefix
      # sniffing alone. Tolerates malformed input: unrecognized lines outside
      # a hunk classify as `Kind::Meta`. An empty diff yields an empty array.
      def self.parse(diff : String) : Array(Line)
        out = [] of Line
        old_left = 0
        new_left = 0

        diff.each_line do |line|
          if old_left > 0 || new_left > 0
            # Hunk body: prefix decides, counts track the remaining extent.
            if line.starts_with?('\\')
              # `\ No newline at end of file` — annotates the previous line,
              # consumes no count.
              out << Line.new(:meta, line)
            elsif line.starts_with?('+')
              out << Line.new(:add, line)
              new_left -= 1
            elsif line.starts_with?('-')
              out << Line.new(:del, line)
              old_left -= 1
            else
              # Context (a leading space, or a producer's bare empty line).
              out << Line.new(:context, line)
              old_left -= 1
              new_left -= 1
            end
          elsif md = line.match(HUNK_HEADER)
            old_left = md[2]?.try(&.to_i) || 1
            new_left = md[4]?.try(&.to_i) || 1
            out << Line.new(:hunk, line)
          elsif line.starts_with?("--- ") || line.starts_with?("+++ ") || line.starts_with?("diff ")
            out << Line.new(:file, line)
          elsif line.starts_with?("Binary files ") || line == "GIT binary patch"
            out << Line.new(:binary, line)
          else
            out << Line.new(:meta, line)
          end
        end
        out
      end

      # Trims hunk context down to at most *context* lines around each
      # add/del, replacing every elided run with a `Kind::Elision` marker
      # (`… N unchanged lines`). Non-context lines are always kept; runs
      # never elide across hunk/file boundaries. Returns *lines* itself for
      # `context < 0` (nothing to do).
      def self.trim(lines : Array(Line), context : Int32) : Array(Line)
        return lines if context < 0

        # A context line survives when within *context* lines of a change on
        # either side. `Meta` (the no-newline annotation) is transparent —
        # it neither breaks adjacency nor counts as distance.
        far = Int32::MAX
        dist = far
        keep = lines.map do |line|
          case line.kind
          in .add?, .del?
            dist = 0
            true
          in .context?
            dist += 1 unless dist == far
            dist <= context
          in .meta?
            true
          in .hunk?, .file?, .binary?, .elision?
            dist = far
            true
          end
        end
        dist = far
        (lines.size - 1).downto(0) do |i|
          case lines[i].kind
          in .add?, .del?
            dist = 0
          in .context?
            dist += 1 unless dist == far
            keep[i] ||= dist <= context
          in .meta?
            # transparent
          in .hunk?, .file?, .binary?, .elision?
            dist = far
          end
        end

        out = Array(Line).new(lines.size)
        dropped = 0
        lines.each_with_index do |line, i|
          if keep[i]
            if dropped > 0
              out << Line.new(:elision, "#{Glyphs::ELLIPSIS} #{dropped} unchanged line#{dropped == 1 ? "" : "s"}")
              dropped = 0
            end
            out << line
          else
            dropped += 1
          end
        end
        if dropped > 0
          out << Line.new(:elision, "#{Glyphs::ELLIPSIS} #{dropped} unchanged line#{dropped == 1 ? "" : "s"}")
        end
        out
      end

      # Parses *diff* and returns its classified lines, context-trimmed when
      # *context* is given (see `.trim`).
      def self.lines(diff : String, *, context : Int32? = nil) : Array(Line)
        parsed = parse diff
        context ? trim(parsed, context) : parsed
      end

      # *diff* as `{}`-tag-styled text, one styled line per diff line — the
      # form for tag-parsing widgets (dialog bodies, previews). Empty diff
      # formats to `""`.
      def self.format(diff : String, *, context : Int32? = nil) : String
        lines(diff, context: context).join('\n', &.styled)
      end

      # *diff* as plain (untagged) text for a `Transcript` `Kind::Diff` entry
      # body — the transcript styles `+`/`-` lines itself, so this only
      # normalizes newlines and applies optional context trimming.
      def self.entry_text(diff : String, *, context : Int32? = nil) : String
        lines(diff, context: context).join('\n', &.text)
      end
    end
  end
end
