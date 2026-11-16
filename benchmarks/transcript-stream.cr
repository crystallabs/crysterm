require "../src/crysterm"

# Streaming a reply into the tail entry of a `Widget::Chat::Transcript`
# (`#update_last` once per token) under a history of N earlier entries. Each
# token grows the tail entry's last line, so the old rendering is not a
# prefix of the new one: the path that re-splices the tail lines.
#
# Reports the total for 500 tokens and the cost per token, for plain bodies
# (a tool result) and markdown prose, and checks that the streamed transcript
# ends up with the same wrapped lines as one built from the final texts.
#
# Run:  crystal run --release benchmarks/transcript-stream.cr

private alias BenchTranscript = Crysterm::Widget::Chat::Transcript

private def transcript_with_history(n : Int32)
  s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 100, height: 40, optimization: Crysterm::OptimizationFlag::None)
  t = BenchTranscript.new parent: s, top: 0, left: 0, width: 90, height: 30
  n.times do |i|
    case i % 3
    when 0 then t.append :prose, "Message #{i}: the quick brown fox jumps over the lazy dog, twice over."
    when 1 then t.append :tool_call, "Bash(make spec-#{i})", state: :ok
    else        t.append :tool_result, "#{i} examples, 0 failures\nFinished in 1.2 seconds"
    end
  end
  s.repaint
  {s, t}
end

private def stream_text(tokens : Int32) : Array(String)
  acc = ""
  Array.new(tokens) do |i|
    acc += (i % 14 == 13 ? "\n" : " ") unless i == 0
    acc += "token#{i}"
    acc
  end
end

private def same_lines?(a : BenchTranscript, b : BenchTranscript) : Bool
  ca = a.wrapped_lines
  cb = b.wrapped_lines
  ca.lines == cb.lines && ca.fake == cb.fake && ca.rtof == cb.rtof && ca.ftor == cb.ftor &&
    ca.max_width == cb.max_width && ca.attr == cb.attr && a.content == b.content
end

TOKENS = 500
texts = stream_text(TOKENS)

{Crysterm::Widget::Chat::Transcript::Kind::ToolResult, Crysterm::Widget::Chat::Transcript::Kind::Prose}.each do |kind|
  STDERR.puts "#{kind} tail entry, #{TOKENS} tokens:"
  {300, 1000, 3000}.each do |n|
    s, t = transcript_with_history(n)
    t.append kind, "token"
    GC.collect
    b0 = GC.stats.total_bytes
    t0 = Time.instant
    texts.each { |text| t.update_last(&.text=(text)) }
    dt = Time.instant - t0
    db = GC.stats.total_bytes - b0
    s.repaint

    _, ref = transcript_with_history(n)
    ref.append kind, texts.last
    STDERR.printf "  history %5d  total %9.1f ms  %8.1f µs/token  %9.1f KiB/token  %s\n",
      n, dt.total_milliseconds, dt.total_microseconds / TOKENS, db.to_f / TOKENS / 1024,
      same_lines?(t, ref) ? "same as one-shot" : "MISMATCH"
  end
end
