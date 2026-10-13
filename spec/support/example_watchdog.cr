# Ends the spec run, naming the example, when an example has not finished
# within `EXAMPLE_TIME_LIMIT` (`SPEC_TIME_LIMIT` seconds, 120 by default).
# An example parked on something that never comes — a child process that
# never answers (`Neovim::Client#request` has no deadline of its own), a
# channel nobody sends to — would otherwise hold up the whole suite with no
# sign of where. (One that keeps the CPU busy without yielding is not
# caught: the watchdog is a fiber.)
EXAMPLE_TIME_LIMIT = (ENV["SPEC_TIME_LIMIT"]?.try(&.to_f?) || 120).seconds

Spec.around_each do |example|
  done = Channel(Nil).new
  spawn(name: "spec watchdog") do
    select
    when done.receive?
    when timeout(EXAMPLE_TIME_LIMIT)
      e = example.example
      STDOUT.flush
      STDERR.puts "\n#{e.file}:#{e.line}: #{e.description.inspect} did not finish within #{EXAMPLE_TIME_LIMIT}"
      STDERR.flush
      Process.exit 1
    end
  end
  begin
    example.run
  ensure
    done.close
  end
end
