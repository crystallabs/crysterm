# Minesweeper — the interactive game. All of the game lives in `game.cr`
# (shared with the self-playing capture demo in `tests/misc/minesweeper.cr`);
# this entry point just picks the difficulty and hands over the terminal.

require "./game"

# Pick difficulty from the first CLI argument (name or 1/2/3); default Beginner.
arg = ARGV[0]?.try(&.downcase)
difficulty =
  case arg
  when "1", "b", "beginner"            then "beginner"
  when "2", "i", "intermediate", "med" then "intermediate"
  when "3", "e", "expert", "hard"      then "expert"
  else                                      "beginner"
  end

Minesweeper.new(difficulty).run
