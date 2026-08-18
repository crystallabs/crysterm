require "./splitter"
require "./toc_view"
require "./text_browser"

module Crysterm
  class Widget
    # A reading pane with a table-of-contents sidebar: a `TextBrowser` and a
    # `TocView` over the same document, side by side in a `Splitter` (Textual's
    # `MarkdownViewer`; Qt has no equivalent).
    #
    # Selecting a sidebar entry jumps the browser to that heading; following a
    # link that loads a new page (via `#loader`) re-points the sidebar at the
    # new document. The sidebar is live — it follows the document as it
    # changes, including one being streamed into.
    #
    # ```
    # mv = Widget::MarkdownViewer.new parent: s, width: 80, height: 24,
    #   document: TextDocument.from_markdown(File.read("README.md"))
    # mv.loader = ->(url : String) { TextDocument.from_markdown(File.read(url)) }
    # ```
    #
    # The parts stay reachable — `#browser` and `#toc_view` — so anything not
    # mirrored here (`#source=`, history, link focus, tree navigation) is a
    # call on the part itself.
    #
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    # <!-- widget-examples:capture v1 -->
    # ![MarkdownViewer screenshot](../../tests/widget/markdown_viewer/markdown_viewer.5s.apng)
    # <!-- /widget-examples:capture -->
    class MarkdownViewer < Splitter
      # The reading pane. Focus it to read: `Tab` cycles links, `Enter`
      # follows, `Backspace` goes back.
      getter browser : TextBrowser

      # The sidebar outline. Focus it to navigate: arrows move, `Enter` jumps
      # the browser to the selected heading.
      getter toc_view : TocView

      # Whether the sidebar is shown (Textual's `show_table_of_contents`).
      getter? show_toc : Bool

      # Sidebar extent along the split axis, in content cells. The reader can
      # still drag the divider; this is the extent a (re)shown sidebar gets.
      getter toc_width : Int32

      def initialize(document : TextDocument? = nil, show_toc : Bool = true, toc_width : Int32 = 24, **input)
        @show_toc = show_toc
        @toc_width = toc_width
        @toc_view = TocView.new
        @browser = TextBrowser.new
        super(**input)

        add_widget @toc_view if show_toc
        add_widget @browser
        apply_toc_width if show_toc

        @toc_view.on(Crysterm::Event::AnchorClick) { |e| @browser.activate_link e.url }
        # A followed link may replace the browser's document (`#loader`); a
        # same-document jump emits the same event, so re-point only on an
        # actual replacement — reassigning the same document would force a
        # sidebar rebuild per jump.
        @browser.on(Crysterm::Event::SourceChanged) do
          doc = @browser.document
          @toc_view.document = doc unless @toc_view.document.same? doc
        end

        document ? (self.document = document) : (@toc_view.document = @browser.document)
      end

      # The document both panes show.
      def document : TextDocument
        @browser.document
      end

      # Shows *doc* in the browser and outlines it in the sidebar.
      def document=(doc : TextDocument) : TextDocument
        @browser.document = doc
        @toc_view.document = doc
        doc
      end

      # The browser's URL resolver (see `TextBrowser#loader`); without one,
      # only same-document links work.
      def loader : Proc(String, TextDocument?)?
        @browser.loader
      end

      # :ditto:
      def loader=(loader : Proc(String, TextDocument?)?)
        @browser.loader = loader
      end

      # Shows or hides the sidebar. Hiding detaches the `TocView` (it keeps
      # tracking the document); showing puts it back at `#toc_width`.
      def show_toc=(value : Bool) : Bool
        return value if value == @show_toc
        @show_toc = value
        if value
          insert_widget 0, @toc_view
          apply_toc_width
        else
          remove_widget @toc_view
        end
        update!
        value
      end

      # Resizes the sidebar to *value* cells (when shown).
      def toc_width=(value : Int32) : Int32
        return value if value == @toc_width
        @toc_width = value
        apply_toc_width if show_toc?
        value
      end

      private def apply_toc_width : Nil
        self.sizes = [@toc_width]
      end
    end
  end
end
