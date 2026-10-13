require "./spec_helper"

include Crysterm

# `Event::ContentsChangeFinished` is Qt's `QTextDocument::contentsChanged()`:
# once per edit, when the outermost edit block ends (or after a lone edit,
# an undo or redo, a whole-text set), after the steps' `ContentsChanged`
# (Qt's `contentsChange`) and with the undo state already current.

private class Log
  getter entries = [] of String

  def initialize(doc : TextDocument)
    doc.on(Event::ContentsChanged) { |e| @entries << "change #{e.kind}" }
    doc.on(Event::ContentsChangeFinished) { @entries << "finished" }
    doc.on(Event::ModificationChanged) { |e| @entries << "modified #{e.modified}" }
  end

  def finished : Int32
    @entries.count("finished")
  end
end

describe TextDocument do
  describe "ContentsChangeFinished" do
    it "comes after a lone edit, after its step and the undo state" do
      doc = TextDocument.new "hello"
      log = Log.new doc
      doc.cursor(5).insert_text "!"
      log.entries.should eq ["change Edit", "modified true", "finished"]
    end

    it "comes once at the end of the outermost edit block" do
      doc = TextDocument.new "hello"
      log = Log.new doc
      cur = doc.cursor(0)
      cur.edit do |c|
        c.insert_text "a"
        doc.edit do
          c.insert_text "b"
        end
        log.finished.should eq 0
        c.insert_text "c"
      end
      log.entries.count("change Edit").should eq 3
      log.finished.should eq 1
      log.entries.last.should eq "finished"
    end

    it "does not come for an edit block that changed nothing" do
      doc = TextDocument.new "hello"
      log = Log.new doc
      doc.edit { }
      log.finished.should eq 0
    end

    it "comes once for an undo and a redo of a block of steps" do
      doc = TextDocument.new "hello"
      doc.cursor(0).edit do |c|
        c.insert_text "a"
        c.set_position 6
        c.insert_text "b"
      end
      log = Log.new doc
      doc.undo.should be_true
      doc.to_plain_text.should eq "hello"
      log.entries.count("change Edit").should eq 2
      log.finished.should eq 1
      log.entries.last.should eq "finished"
      doc.redo.should be_true
      log.finished.should eq 2
    end

    it "comes once for a whole-text set, inside a block at its end" do
      doc = TextDocument.new "hello"
      log = Log.new doc
      doc.set_plain_text "other"
      log.finished.should eq 1
      doc.edit do
        doc.set_plain_text "third"
        log.finished.should eq 1
      end
      log.finished.should eq 2
    end

    it "comes for a format change" do
      doc = TextDocument.new "hello"
      log = Log.new doc
      cur = doc.cursor(0)
      cur.set_position 5, :keep_anchor
      cur.merge_char_format TextCharFormat.new(bold: true)
      log.finished.should eq 1
    end

    it "does not come for a block's overlay" do
      doc = TextDocument.new "hello"
      log = Log.new doc
      doc.blocks[0].user_state = 3
      log.entries.should eq ["change Format"]
    end

    it "comes for a table cell's many steps once" do
      doc = TextDocument.new ""
      table = doc.cursor(0).insert_table(2, 2)
      log = Log.new doc
      table.set_cell_text(0, 0, "x")
      log.entries.count(&.starts_with?("change")).should be > 1
      log.finished.should eq 1
    end
  end
end
