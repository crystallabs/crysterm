require "../src/crysterm"

# `TextMarkdown::Stream#append` under a long construct that releases nothing
# until it closes: one code fence of S bytes, streamed in 16-byte chunks. The
# whole fence stays pending, so this measures what a chunk costs as the
# pending tail grows.
#
# The fence's close is timed apart: it releases the whole fence as one piece,
# which the stream first has the markdown parser confirm.
#
# Run:  crystal run --release benchmarks/markdown-stream-pending.cr

private def fence_chunks(bytes : Int32, chunk : Int32) : Array(String)
  body = String.build do |io|
    io << "```crystal\n"
    i = 0
    while io.bytesize < bytes
      io << "  puts \"line " << i << " of a long fenced block\"\n"
      i += 1
    end
  end
  chunks = [] of String
  pos = 0
  while pos < body.bytesize
    n = Math.min(chunk, body.bytesize - pos)
    chunks << body.byte_slice(pos, n)
    pos += n
  end
  chunks
end

{64 * 1024, 256 * 1024, 1024 * 1024}.each do |bytes|
  chunks = fence_chunks(bytes, 16)
  stream = Crysterm::TextMarkdown::Stream.new
  released = 0
  GC.collect
  b0 = GC.stats.total_bytes
  t0 = Time.instant
  chunks.each { |c| stream.append(c).try { |piece| released += piece.bytesize } }
  dt = Time.instant - t0
  db = GC.stats.total_bytes - b0

  t0 = Time.instant
  stream.append("```\n\nafter\n\n").try { |piece| released += piece.bytesize }
  stream.flush.try { |piece| released += piece.bytesize }
  dc = Time.instant - t0
  STDERR.printf "fence %5d KiB in %6d chunks: %9.1f ms  %7.2f µs/chunk  %9.1f MiB alloc  (close + release %8.1f ms, %d bytes)\n",
    bytes // 1024, chunks.size, dt.total_milliseconds, dt.total_microseconds / chunks.size,
    db.to_f / 1024 / 1024, dc.total_milliseconds, released
end
