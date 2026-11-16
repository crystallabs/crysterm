require "./spec_helper"

private alias R2Transcript = Crysterm::Widget::Chat::Transcript

# A document with a table of contents at its top, over the headings of *md*.
private def r2_toc_doc(md : String) : Crysterm::TextDocument
  doc = Crysterm::TextDocument.from_markdown md
  Crysterm::TextCursor.new(doc).insert_toc
  doc
end

private def r2_toc_lines(doc : Crysterm::TextDocument) : Array(String)
  doc.tocs.first.blocks.map(&.text)
end

private def r2_transcript(history : Int32) : R2Transcript
  s = headless_screen(100, 40)
  t = R2Transcript.new parent: s, top: 0, left: 0, width: 60, height: 20
  history.times do |i|
    if i.even?
      t.append :prose, "Message #{i} with {braces} and text"
    else
      t.append :tool_call, "Bash(run #{i})", state: :ok
    end
  end
  s.repaint
  t
end

private def r2_same_lines(a : R2Transcript, b : R2Transcript) : Nil
  ca = a.wrapped_lines
  cb = b.wrapped_lines
  ca.lines.should eq cb.lines
  ca.fake.should eq cb.fake
  ca.rtof.should eq cb.rtof
  ca.ftor.should eq cb.ftor
  ca.attr.should eq cb.attr
  ca.max_width.should eq cb.max_width
  a.content.should eq b.content
  a.lines.should eq b.lines
end

private class R2StateHighlighter < Crysterm::SyntaxHighlighter
  property color = "red"

  def highlight_block(text : String)
    set_format(0, 1, @color) unless text.empty?
    self.current_block_state = @color == "red" ? 1 : 2
  end
end

describe "TextToc#refresh and the undo history" do
  it "undoes an edit made before the refresh at its own place" do
    doc = r2_toc_doc "# One\n\nbody"
    c = doc.cursor(doc.size)
    c.insert_block Crysterm::TextBlockFormat.new(heading_level: 2)
    c.insert_text "Two"
    doc.refresh_tocs.should be_true
    r2_toc_lines(doc).should eq ["One", "Two"]

    doc.undo.should be_true
    doc.blocks.map(&.text).should eq ["One", "Two", "One", "body", ""]
    doc.redo.should be_true
    doc.blocks.map(&.text).should eq ["One", "Two", "One", "body", "Two"]
  end

  it "walks the whole history back and forth across a refresh" do
    doc = Crysterm::TextDocument.from_markdown "# One\n\nbody"
    original = doc.blocks.map(&.text)
    Crysterm::TextCursor.new(doc).insert_toc
    c = doc.cursor(doc.size)
    c.insert_block Crysterm::TextBlockFormat.new(heading_level: 2)
    c.insert_text "Two"
    doc.refresh_tocs.should be_true
    c.insert_text "!"
    final = doc.blocks.map(&.text)
    final.should eq ["One", "Two", "One", "body", "Two!"]

    while doc.undo_available?
      doc.undo.should be_true
    end
    doc.blocks.map(&.text).should eq original
    while doc.redo_available?
      doc.redo.should be_true
    end
    doc.blocks.map(&.text).last.should eq "Two!"
    doc.blocks.map(&.text)[-3..].should eq ["One", "body", "Two!"]
  end

  it "leaves the refreshed entries as they are when a later edit is undone" do
    doc = r2_toc_doc "# One\n\nbody"
    c = doc.cursor(doc.size)
    c.insert_block Crysterm::TextBlockFormat.new(heading_level: 2)
    c.insert_text "Two"
    doc.refresh_tocs.should be_true
    c.insert_text " more"

    doc.undo.should be_true
    r2_toc_lines(doc).should eq ["One", "Two"]
    doc.blocks.last.text.should eq "Two"
    doc.undo.should be_true
    r2_toc_lines(doc).should eq ["One", "Two"]
    doc.blocks.last.text.should eq ""
  end

  it "keeps a cursor after the table of contents on its text across the replay" do
    doc = r2_toc_doc "# One\n\nbody"
    c = doc.cursor(doc.size)
    c.insert_block Crysterm::TextBlockFormat.new(heading_level: 2)
    c.insert_text "Two"
    doc.refresh_tocs.should be_true
    caret = doc.cursor(0)
    doc.undo(caret).should be_true
    caret.position.should eq doc.size
  end
end

describe "Tag name characters" do
  it "are the same for the tag regex and the tokenizer" do
    {'a', 'Z', '0', '_', '-', ',', ';', '!', '#', 'é', 'ß', 'я', '٣', '=', ' ', '|'}.each do |ch|
      Crysterm::TextTags::TAG_REGEX.matches?("{#{ch}}").should eq Crysterm::TextTags.tag_name_char?(ch)
    end
  end

  it "leaves a brace pair around a non-ASCII word in the text when cleaning tags" do
    s = headless_screen(20, 5)
    box = Crysterm::Widget::Box.new parent: s, width: 20, height: 3
    box.clean_tags("{é}x{bold}y{/bold}").should eq "{é}xy"
  end
end

describe "Widget::Terminal child process handling" do
  it "keeps reading the child after a handler of its output raises" do
    s = headless_screen(80, 24)
    app = s.application || Crysterm::Application.global
    seen = [] of Exception
    sub = app.on(Crysterm::Event::HandlerError) { |e| seen << e.error }
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 40, height: 4,
      shell: "sh", args: ["-c", "printf '\\033]0;boom\\007'; sleep 0.2; printf AFTER; sleep 5"])
    term.on(Crysterm::Event::ContentSet) { raise "title handler" if term.title == "boom" }
    s.repaint
    em = term.emulator.not_nil!

    wait_until(5.seconds) { emu_row(em, 0).includes?("AFTER") }
    seen.map(&.message).should eq ["title handler"]
  ensure
    sub.try &.off
    term.try &.kill
    s.try &.destroy
  end

  it "reports a shell that cannot be started as an exited process" do
    s = headless_screen(80, 24)
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 60, height: 4,
      shell: "/nonexistent/crysterm-round2-shell")
    codes = [] of Int32?
    term.on(Crysterm::Event::ProcessExited) { |e| codes << e.code }
    s.repaint

    wait_until(5.seconds) { codes.size == 1 }
    codes.first.should eq 127
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

describe "Widget::MarkdownViewer with its sidebar hidden" do
  it "destroys the sidebar with the viewer" do
    s = headless_screen(80, 24)
    doc = Crysterm::TextDocument.from_markdown "# One\n\nbody"
    mv = Crysterm::Widget::MarkdownViewer.new parent: s, width: 80, height: 24, document: doc
    s.repaint
    mv.show_toc = false
    destroyed = 0
    mv.toc_view.on(Crysterm::Event::Destroy) { destroyed += 1 }
    before = doc.handlers(Crysterm::Event::ContentsChanged).size

    mv.destroy
    destroyed.should eq 1
    doc.handlers(Crysterm::Event::ContentsChanged).size.should be < before
  end

  it "destroys a shown sidebar once" do
    s = headless_screen(80, 24)
    mv = Crysterm::Widget::MarkdownViewer.new parent: s, width: 80, height: 24,
      document: Crysterm::TextDocument.from_markdown("# One\n\nbody")
    s.repaint
    destroyed = 0
    mv.toc_view.on(Crysterm::Event::Destroy) { destroyed += 1 }
    mv.destroy
    destroyed.should eq 1
  end
end

describe "Widget::Media::Tek animation and visibility" do
  it "stops drawing while hidden and starts again when shown" do
    gif = "data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)

    s = headless_screen(default_quit_keys: true)
    tek = Crysterm::Widget::Media::Tek.new file: gif, parent: s
    tek.draw_tek
    tek.playing?.should be_true

    tek.hide
    tek.playing?.should be_false
    tek.draw_tek
    tek.playing?.should be_false

    tek.show
    tek.draw_tek
    tek.playing?.should be_true
  ensure
    tek.try &.stop
    s.try &.destroy
  end

  it "stops drawing when detached from its window" do
    gif = "data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)

    s = headless_screen(default_quit_keys: true)
    tek = Crysterm::Widget::Media::Tek.new file: gif, parent: s
    tek.draw_tek
    tek.playing?.should be_true

    s.remove tek
    tek.playing?.should be_false
  ensure
    tek.try &.stop
    s.try &.destroy
  end

  it "stays stopped when shown again after an explicit stop" do
    gif = "data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)

    s = headless_screen(default_quit_keys: true)
    tek = Crysterm::Widget::Media::Tek.new file: gif, parent: s
    tek.draw_tek
    tek.hide
    tek.stop
    tek.show
    tek.draw_tek
    tek.playing?.should be_false
  ensure
    tek.try &.stop
    s.try &.destroy
  end
end

describe "Widget::Chat::Transcript#update_last streaming" do
  it "ends with the lines a transcript built from the final text has" do
    {R2Transcript::Kind::ToolResult, R2Transcript::Kind::Prose, R2Transcript::Kind::Error}.each do |kind|
      t = r2_transcript(40)
      t.append R2Transcript::Entry.new(kind, "start")
      text = "start"
      60.times do |i|
        text += (i % 7 == 6 ? "\n" : " ") + (i % 11 == 0 ? "{b#{i}} **bold#{i}**" : "word#{i}")
        t.update_last(&.text=(text))
      end
      # A rewrite that shortens the entry, then growth again.
      text = "start over"
      t.update_last(&.text=(text))
      10.times do |i|
        text += "\nline #{i} of the rewritten entry that is long enough to wrap around the transcript width"
        t.update_last(&.text=(text))
      end

      ref = r2_transcript(40)
      ref.append R2Transcript::Entry.new(kind, text)
      r2_same_lines t, ref
    end
  end

  it "keeps the earlier entries when the tail entry is emptied and refilled" do
    t = r2_transcript(6)
    e = t.append :tool_result, "one\ntwo\nthree"
    e.text = "one\ntwo\nthree four"
    t.update_last e
    e.text = "one"
    t.update_last e
    e.text = "one\ntwo"
    t.update_last e

    ref = r2_transcript(6)
    ref.append :tool_result, "one\ntwo"
    r2_same_lines t, ref
  end

  it "reparses to the same lines after streaming" do
    t = r2_transcript(10)
    t.append :tool_result, "a"
    text = "a"
    30.times do |i|
      text += " w#{i}"
      t.update_last(&.text=(text))
    end
    before = t.wrapped_lines.lines.dup
    t.width = 50
    t.process_content
    t.width = 60
    t.process_content
    t.wrapped_lines.lines.should eq before
  end
end

describe "Widget#drop_appended_content" do
  it "takes the last appended lines back, leaving what a reparse gives" do
    s = headless_screen(60, 20)
    box = Crysterm::Widget::Box.new parent: s, width: 30, height: 10
    box.parse_tags = true
    box.set_content "first {bold}line{/bold}\nsecond"
    s.repaint
    box.append_content("{red-fg}third{/red-fg} line that is long enough to wrap around\nfourth").should be_true
    box.drop_appended_content.should eq 2

    ref = Crysterm::Widget::Box.new parent: s, width: 30, height: 10
    ref.parse_tags = true
    ref.set_content "first {bold}line{/bold}\nsecond"
    box.wrapped_lines.lines.should eq ref.wrapped_lines.lines
    box.wrapped_lines.fake.should eq ref.wrapped_lines.fake
    box.wrapped_lines.rtof.should eq ref.wrapped_lines.rtof
    box.wrapped_lines.ftor.should eq ref.wrapped_lines.ftor
    box.wrapped_lines.max_width.should eq ref.wrapped_lines.max_width
    box.content.should eq "first {bold}line{/bold}\nsecond"

    # Nothing appended since: nothing to take back.
    box.drop_appended_content.should be_nil
    box.append_content("tail").should be_true
    box.content.should eq "first {bold}line{/bold}\nsecond\ntail"
  end

  it "takes an append back after the content was read" do
    s = headless_screen(60, 20)
    box = Crysterm::Widget::Box.new parent: s, width: 30, height: 10
    box.set_content "one\ntwo"
    s.repaint
    box.append_content("three\nfour").should be_true
    box.content.should eq "one\ntwo\nthree\nfour"
    box.drop_appended_content.should eq 2
    box.content.should eq "one\ntwo"
    box.wrapped_lines.fake.should eq ["one", "two"]
  end

  it "does not take an append back once the content changed otherwise" do
    s = headless_screen(60, 20)
    box = Crysterm::Widget::Box.new parent: s, width: 30, height: 10
    box.set_content "one\ntwo"
    s.repaint
    box.append_content("three").should be_true
    box.set_content "other\ntext\nthree"
    box.drop_appended_content.should be_nil
    box.content.should eq "other\ntext\nthree"
  end
end

describe "TextMarkdown::Stream pending text" do
  it "releases the same pieces however the input is chunked" do
    md = "# Title\n\npara one\nstill one\n\n```cr\ncode\n\nmore code\n```\n\n- a\n- b\n\nlast para\n\ntail"
    whole = [] of String
    st = Crysterm::TextMarkdown::Stream.new
    st.append(md).try { |p| whole << p }
    whole_pending = st.pending
    st.flush.try { |p| whole << p }

    {1, 3, 7}.each do |n|
      pieces = [] of String
      st = Crysterm::TextMarkdown::Stream.new
      pos = 0
      while pos < md.size
        st.append(md[pos, n]).try { |p| pieces << p }
        pos += n
      end
      st.pending.should eq whole_pending
      st.flush.try { |p| pieces << p }
      pieces.join.should eq whole.join
      st.pending.should eq ""
    end
  end

  it "takes a line break split across two chunks as one" do
    st = Crysterm::TextMarkdown::Stream.new
    st.append("a\r").should be_nil
    st.append("\nb")
    st.pending.should eq "a\nb"
  end
end

describe "SyntaxHighlighter overlay changes" do
  it "tells the document's views once for a whole rehighlight" do
    doc = Crysterm::TextDocument.new("one\ntwo\nthree\nfour")
    hl = R2StateHighlighter.new(doc)
    pokes = 0
    doc.on(Crysterm::Event::ContentsChanged) { pokes += 1 }
    rev = doc.revision

    hl.color = "blue"
    hl.rehighlight
    pokes.should eq 1
    doc.revision.should be > rev
    doc.blocks.map(&.user_state).should eq [2, 2, 2, 2]
    doc.blocks.all? { |b| b.additional_formats.try(&.size) == 1 }.should be_true

    # Nothing changes: nothing told.
    hl.rehighlight
    pokes.should eq 1
  end

  it "still tells of an overlay written outside a highlight pass" do
    doc = Crysterm::TextDocument.new("one\ntwo")
    pokes = 0
    doc.on(Crysterm::Event::ContentsChanged) { pokes += 1 }
    doc.blocks[0].user_state = 7
    doc.blocks[1].user_state = 7
    pokes.should eq 2
  end
end
