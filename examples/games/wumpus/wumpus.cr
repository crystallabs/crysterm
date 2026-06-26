require "../../../src/crysterm"

# Hunt the Wumpus
# ===============
#
# A faithful little port of Gregory Yob's 1973 classic, built as a Crysterm
# example. You explore a fixed cave of 20 rooms laid out as a dodecahedron
# (every room connects to exactly three others) hunting the Wumpus. You can't
# see it, if you enter the room he wakes up and eats you. Try deduce its
# location from warnings in adjacent rooms, then fire a "crooked arrow"
# through up to 5 rooms to kill it. Arrows can veer as you want, but you
# must know room numbers.
#
# Hazards:
#   * The Wumpus     - shoot it to win; bump into it and it eats you.
#   * Bottomless pits- fall in and you're gone.
#   * Super bats     - pick you up and drop you in a random room.
# A pit, bats, and The Wumpus can be in the same room. You cannot.
#
# Commands (typed into the input box, then Enter):
#   <room> / m <room>  move to an adjacent room
#   s <room> [room…]   shoot an arrow through up to 5 rooms
#   b                  go back to your previous room (needs the "back" flag)
#   n                  start a new game
#   h                  help (also shows current flags)
#   q / Ctrl-Q         quit

class Wumpus
  include Crysterm

  # The canonical dodecahedron map from the original game. Room N (1-based)
  # connects to the three rooms listed.
  MAP = {
    1 => {2, 5, 8}, 2 => {1, 3, 10}, 3 => {2, 4, 12}, 4 => {3, 5, 14},
    5 => {1, 4, 6}, 6 => {5, 7, 15}, 7 => {6, 8, 17}, 8 => {1, 7, 11},
    9 => {10, 12, 19}, 10 => {2, 9, 11}, 11 => {8, 10, 20}, 12 => {3, 9, 13},
    13 => {12, 14, 18}, 14 => {4, 13, 15}, 15 => {6, 14, 16}, 16 => {15, 17, 18},
    17 => {7, 16, 20}, 18 => {13, 16, 19}, 19 => {9, 18, 20}, 20 => {11, 17, 19},
  }

  STARTING_ARROWS = 5

  # Every difference between the flavors, as an independent on/off flag.
  FLAGS = %w[mesg prompts bump crooked same back reveal gap]

  # One-line description of each flag, for the help screen.
  FLAG_HELP = {
    "mesg"    => "ALL-CAPS messages (off = modern, colorized)",
    "prompts" => "longer prompts",
    "bump"    => "bump the Wumpus only wakes it (off = instant loss)",
    "crooked" => "allow a shot that doubles back, A->B->A (off = no)",
    "same"    => "ask SAME SET-UP? to replay cave (off = reshuffle)",
    "back"    => "enable 'b' for step-back command",
    "reveal"  => "reveal the Wumpus's room after loss",
    "gap"     => "teletype blank-line spacing (off = compact)",
  }

  # Named groups of flag settings. The default pack is the first key.
  PRESETS = {
    "1973" => {"mesg" => true, "prompts" => true, "bump" => true, "crooked" => false,
               "same" => true, "back" => false, "reveal" => false, "gap" => true},
    "2026" => {"mesg" => false, "prompts" => false, "bump" => false, "crooked" => true,
               "same" => false, "back" => true, "reveal" => true, "gap" => false},
  }

  @player = 1
  @prev_player = 1 # room occupied before the current one (for the "back" flag)
  @wumpus = 1
  @prev_wumpus = 1 # the Wumpus's room as of the start of the current turn (for the loss reveal)
  @pits = [] of Int32
  @bats = [] of Int32
  @arrows = STARTING_ARROWS

  # Initial layout, kept for the "SAME SET-UP (Y-N)?" replay (the "same" flag).
  @start_player = 1
  @start_wumpus = 1
  @start_pits = [] of Int32
  @start_bats = [] of Int32

  # After a game ends with "same" on we ask "SAME SET-UP (Y-N)?" and the next
  # y/n answer is interpreted here instead of as a move.
  @awaiting_replay = false

  # Whether any game has started yet, so new_game can separate each fresh prolog
  # from the previous game with a blank line (but not at the very top).
  @started = false

  # With "prompts" on, input is a teletype sequence spanning several Enter
  # presses; this tracks which answer we are waiting for:
  #   :command      - the top-level "SHOOT OR MOVE (S-M)?"
  #   :move_target  - "WHERE TO?" (a room number)
  #   :shoot_count  - "NO. OF ROOMS (1-5)?"
  #   :shoot_rooms  - "ROOM #?" (collected one at a time into @shoot_path)
  @input_state = :command
  @shoot_needed = 0
  @shoot_path = [] of Int32

  def initialize(@opt : Hash(String, Bool))
    @screen = Screen.new title: "Hunt the Wumpus"

    @transcript = Widget::PlainTextEdit.new \
      top: 0,
      left: 0,
      width: "100%",
      height: "100%-3",
      content: "",
      parse_tags: true,
      scrollbar: true,
      style: Style.new(fg: "white", bg: "#1a1a2e", border: true,
        scrollbar: Style.new(bg: "#5555aa"))

    @input = Widget::LineEdit.new \
      top: "100%-3",
      left: 0,
      width: "100%",
      height: 3,
      style: Style.new(fg: "black", bg: "#e0e000", border: true)

    @screen.append @transcript
    @screen.append @input
    @input.focus

    @input.on(Event::Submit) do |e|
      text = e.value.to_s.strip
      # Echo the typed line into the transcript so the back-and-forth stays in
      # the scrollback (like a real teletype). Braces are neutralized so user
      # input can never be mistaken for {tag} markup.
      say "> #{text.gsub('{', '(').gsub('}', ')')}" unless text.empty?
      handle_command text
      @input.value = ""
      @input.focus
      @screen.render
    end

    @screen.on(Event::KeyPress) do |e|
      if e.key == Tput::Key::CtrlQ
        @screen.destroy
        exit
      end
    end
  end

  def run
    new_game
    @screen.exec
  end

  # ---- Flags -----------------------------------------------------------------

  private def mesg?
    @opt["mesg"]
  end

  private def prompts?
    @opt["prompts"]
  end

  private def bump?
    @opt["bump"]
  end

  private def crooked?
    @opt["crooked"]
  end

  private def same?
    @opt["same"]
  end

  private def back?
    @opt["back"]
  end

  private def reveal?
    @opt["reveal"]
  end

  private def gap?
    @opt["gap"]
  end

  # Pick original (1973) vs modern (2026) wording for a line, per the mesg flag.
  private def w(orig : String, modern : String) : String
    mesg? ? orig : modern
  end

  # Apply one configuration token to an options hash: a pack name ("1973"), a
  # bare flag name ("bump", which toggles it), or a forced "+flag" / "-flag".
  # Shared by the command-line args at startup and by typed input mid-game.
  # Returns the name of the single flag changed, "" for a preset, or nil if the
  # token wasn't recognized.
  def self.apply_arg(opts : Hash(String, Bool), token : String) : String?
    token = token.downcase
    if pack = PRESETS[token]?
      pack.each { |k, v| opts[k] = v }
      ""
    elsif (token.starts_with?('+') || token.starts_with?('-')) && FLAGS.includes?(token.lchop)
      opts[token.lchop] = token.starts_with?('+')
      token.lchop
    elsif FLAGS.includes?(token)
      opts[token] = !opts[token]
      token
    else
      nil
    end
  end

  # Re-render the current room after a flag/preset change, in the new style. The
  # game state (player, hazards, arrows) is untouched; only a half-entered
  # teletype prompt is abandoned, since the input model itself may have changed.
  private def refresh_options
    @input_state = :command
    describe_room unless @awaiting_replay
  end

  # Current config as a list of +flag / -flag tokens — which is exactly what you
  # can type back to set them (e.g. "+bump", "-reveal").
  private def options_line : String
    FLAGS.map { |f| "#{@opt[f] ? "+" : "-"}#{f}" }.join(" ")
  end

  # ---- Output helpers --------------------------------------------------------

  private def say(line : String = "")
    return if line.empty?
    @transcript.push_line line
    @transcript.scroll_to @transcript.get_content.lines.size
  end

  # A blank separator line — kept when the "gap" flag is on (teletype spacing),
  # omitted when off (compact).
  private def gap
    say if gap?
  end

  # ---- Game setup ------------------------------------------------------------

  private def new_game(reuse = false)
    say if @started # blank line between the previous game and this fresh prolog
    @started = true

    if reuse
      # "SAME SET-UP": restore the exact starting cave.
      @player, @wumpus = @start_player, @start_wumpus
      @pits, @bats = @start_pits.dup, @start_bats.dup
    else
      # Place the player and hazards in six distinct rooms, and remember the
      # layout so a later "SAME SET-UP" can restore it.
      rooms = (1..20).to_a.shuffle
      @player = rooms[0]
      @wumpus = rooms[1]
      @pits = [rooms[2], rooms[3]]
      @bats = [rooms[4], rooms[5]]
      @start_player, @start_wumpus = @player, @wumpus
      @start_pits, @start_bats = @pits.dup, @bats.dup
    end
    @arrows = STARTING_ARROWS
    @awaiting_replay = false
    @input_state = :command
    @prev_player = @player
    @prev_wumpus = @wumpus

    say
    if mesg?
      say "HUNT THE WUMPUS"
    else
      say "{bold}{yellow-fg}HUNT THE WUMPUS{/}"
      say "You enter a cave of 20 rooms. Somewhere a Wumpus sleeps."
      say "You carry #{@arrows} crooked arrows. Find it and shoot it."
    end
    say w("", "Type {bold}h{/} for help.") # always shown
    gap
    describe_room
  end

  # ---- Per-turn description --------------------------------------------------

  private def describe_room
    tunnels = MAP[@player].to_a.sort
    adj = MAP[@player]
    smell = adj.includes?(@wumpus)
    draft = adj.any? { |r| @pits.includes?(r) }
    flap = adj.any? { |r| @bats.includes?(r) }

    if mesg?
      say "I SMELL A WUMPUS!" if smell
      say "I FEEL A DRAFT" if draft
      say "BATS NEARBY!" if flap
      say "YOU ARE IN ROOM #{@player}"
      say "TUNNELS LEAD TO #{tunnels.join(" ")}"
    else
      say "{red-fg}You smell a Wumpus!{/}" if smell
      say "{red-fg}You feel a cold draft.{/}" if draft
      say "{magenta-fg}You hear the flapping of bats.{/}" if flap
      say "You are in room {bold}#{@player}{/}. Tunnels lead to #{tunnels.join(", ")}."
      say "Arrows left: #{@arrows}."
    end

    # The teletype top-level prompt, independent of the wording flag.
    say "SHOOT OR MOVE (S-M)?" if prompts?
  end

  # ---- Command dispatch ------------------------------------------------------

  # With "prompts" on, a turn walks the teletype sequence one Enter at a time
  # (see @input_state); otherwise a whole command is parsed per line.
  private def handle_command(cmd : String)
    return if cmd.empty?
    # Snapshot the Wumpus's room before resolving the turn: if it later stirs
    # onto you (a shot startling it into your room), the reveal still names where
    # it *was*, not the room it died in (which is now yours). See lose.
    @prev_wumpus = @wumpus
    parts = cmd.split(/\s+/)
    verb = parts[0].downcase

    # A pack name ("1973"), a bare flag ("bump", toggles it), or a forced
    # "+flag" / "-flag" reconfigures the game without resetting it — and works
    # any time (even mid-turn). Same token format as the command-line args. For a
    # single flag we echo its new state (+on / -off); presets stay silent.
    if changed = Wumpus.apply_arg(@opt, verb)
      say(@opt[changed] ? "+" : "-") unless changed.empty?
      refresh_options
      return
    end

    # Quit works in any state.
    if verb == "q" || verb == "quit"
      @screen.destroy
      exit
    end

    # "SAME SET-UP (Y-N)?" prompt: the next y/n answer picks the cave.
    if @awaiting_replay
      case verb
      when "y", "yes" then new_game reuse: true
      else                 new_game reuse: false
      end
      return
    end

    # Teletype mid-turn answer to "WHERE TO?" / "NO. OF ROOMS?" / "ROOM #?".
    if prompts? && @input_state != :command
      handle_prompt verb
      return
    end

    case verb
    when "h", "help", "?"
      help
      return
    when "n", "new"
      new_game
      return
    end

    # Step back to the previous room (single-letter "b"), if enabled.
    if back? && verb == "b"
      back
      return
    end

    if prompts?
      # Top-level "SHOOT OR MOVE (S-M)?": S or M start the prompt sequence.
      case verb
      when "s", "shoot"
        @input_state = :shoot_count
        say "NO. OF ROOMS (1-5)?"
      when "m", "move"
        @input_state = :move_target
        say "WHERE TO?"
      else
        say "SHOOT OR MOVE (S-M)?"
      end
      return
    end

    # Free-form one-line commands.
    case verb
    when "s", "shoot"
      path = parts[1..].map(&.to_i?).compact
      if path.empty?
        say "Shoot where? e.g. {bold}s 3 12{/}"
      else
        shoot path
      end
    when "m", "move"
      if (room = parts[1]?.try &.to_i?)
        move room
      else
        say "Move where? e.g. {bold}m 5{/}"
      end
    else
      # Bare number is treated as a move.
      if (room = verb.to_i?)
        move room
      else
        say "Unknown command '#{cmd}'. Type {bold}h{/} for help."
      end
    end
  end

  # Handle one answer in the teletype prompt sequence, re-asking the same prompt
  # on bad input just as the original did.
  private def handle_prompt(verb : String)
    num = verb.to_i?
    case @input_state
    when :move_target # "WHERE TO?"
      if num && move(num)
        @input_state = :command
      else
        # move() already printed "NOT POSSIBLE -" for a non-adjacent room.
        say "WHERE TO?"
      end
    when :shoot_count # "NO. OF ROOMS (1-5)?"
      if num && 1 <= num <= 5
        @shoot_needed = num
        @shoot_path = [] of Int32
        @input_state = :shoot_rooms
        say "ROOM #?"
      else
        say "NO. OF ROOMS (1-5)?"
      end
    when :shoot_rooms # "ROOM #?", collected one at a time
      if num.nil?
        say "ROOM #?"
      elsif !crooked? && @shoot_path.size >= 2 && num == @shoot_path[@shoot_path.size - 2]
        # Doubling straight back (A -> B -> A) is forbidden unless "crooked" is on.
        say "ARROWS AREN'T THAT CROOKED - TRY ANOTHER ROOM"
        say "ROOM #?"
      else
        @shoot_path << num
        if @shoot_path.size < @shoot_needed
          say "ROOM #?"
        else
          @input_state = :command
          shoot @shoot_path
        end
      end
    end
  end

  private def help
    say
    say "{bold}Commands:{/}"
    if prompts?
      say "  m, then WHERE TO?            answer with a room number to move"
      say "  s, then NO. OF ROOMS (1-5)?  then a ROOM # for each, to shoot"
    else
      say "  <room>           move to an adjacent room (e.g. 5)"
      say "  m <room>         move to an adjacent room"
      say "  s <room> [room…] shoot an arrow through up to 5 rooms"
    end
    say "  b                go back to the room you were last in" if back?
    say "  n                start a new game"
    say "  q                quit (also Ctrl-Q)"
    say
    say "{bold}Flags:{/}"
    FLAGS.each do |f|
      say "  #{@opt[f] ? "+" : "-"}#{f.ljust(8)} #{FLAG_HELP[f]}"
    end
    say
    say "{bold}Presets:{/}"
    PRESETS.each do |name, flags|
      say "  #{name.ljust(6)} #{FLAGS.map { |f| "#{flags[f] ? "+" : "-"}#{f}" }.join(" ")}"
    end
    say
  end

  # ---- Moving ----------------------------------------------------------------

  # Returns true if the move succeeded (the room was adjacent).
  private def move(room : Int32) : Bool
    unless MAP[@player].includes?(room)
      say w("NOT POSSIBLE -",
        "You can't get to room #{room} from here. Tunnels: #{MAP[@player].to_a.sort.join(", ")}.")
      return false
    end

    go_to room
    true
  end

  # Relocate the player, remembering where they came from so "back" can step
  # back. Bat snatches set @player directly, so a teleport isn't a "prev" room.
  private def go_to(room : Int32)
    @prev_player = @player
    @player = room
    enter_room
  end

  # "b": step back to the room you were last in (always allowed, even when bats
  # flung you somewhere non-adjacent). Toggling b/b walks you to and fro.
  private def back
    if @prev_player == @player
      say "There's nowhere to go back to yet."
    else
      go_to @prev_player
    end
  end

  # Resolve whatever is in the room the player just walked (or was dropped) into.
  private def enter_room
    if @player == @wumpus
      if bump?
        # A bump only wakes the Wumpus: it stirs (75%) and may shuffle out of
        # your room, so you can survive. Only being eaten ends the game.
        say w("... OOPS! BUMPED A WUMPUS!",
          "{yellow-fg}You blunder into the Wumpus — it wakes with a roar!{/}")
        if wumpus_stirs
          say w("TSK TSK TSK - WUMPUS GOT YOU!",
            "{red-fg}{bold}It lunges and devours you!{/}")
          lose
        else
          gap
          describe_room
        end
      else
        say w("TSK TSK TSK - WUMPUS GOT YOU!",
          "{red-fg}{bold}You walked right into the Wumpus! It gobbles you up.{/}")
        lose
      end
      return
    end

    if @pits.includes?(@player)
      say w("YYYIIIIEEEE . . . FELL IN A PIT",
        "{red-fg}{bold}You plummet into a bottomless pit. Aaaaaa…{/}")
      lose
      return
    end

    if @bats.includes?(@player)
      say w("ZAP--SUPER BAT SNATCH! ELSEWHERE FOR YOU!",
        "{magenta-fg}Super bats snatch you and whisk you away!{/}")
      @player = rand(1..20)
      enter_room # might drop you somewhere nasty
      return
    end

    gap
    describe_room
  end

  # The Wumpus stirs after a shot or a bump: 75% chance it shuffles to a random
  # adjacent room (25% it stays put). Returns true if it ends up eating you.
  private def wumpus_stirs : Bool
    @wumpus = MAP[@wumpus].to_a.sample if rand < 0.75
    @wumpus == @player
  end

  # ---- Shooting --------------------------------------------------------------

  private def shoot(path : Array(Int32))
    if path.size > 5
      say w("NO. OF ROOMS (1-5)?", "An arrow can only fly through 5 rooms.")
      return
    end

    # Unless "crooked" is on, the arrow can't double straight back on itself: no
    # room may equal the one two steps earlier in the path (A -> B -> A).
    unless crooked?
      (2...path.size).each do |i|
        if path[i] == path[i - 2]
          say w("ARROWS AREN'T THAT CROOKED - TRY ANOTHER ROOM",
            "{yellow-fg}That shot would double back on itself — pick another room.{/}")
          return
        end
      end
    end

    # Trace the arrow's flight. A "crooked arrow" must turn between adjacent
    # rooms; if you name a room it can't reach, it veers off randomly.
    pos = @player
    path.each do |target|
      pos = if MAP[pos].includes?(target)
              target
            else
              MAP[pos].to_a.sample
            end

      if pos == @wumpus
        say w("AHA! YOU GOT THE WUMPUS!",
          "{green-fg}{bold}Your arrow strikes the Wumpus! You win!{/}")
        win
        return
      end

      if pos == @player
        say w("OUCH! ARROW GOT YOU!",
          "{red-fg}{bold}Your own arrow circles back and skewers you!{/}")
        lose
        return
      end
    end

    say w("MISSED", "Your arrow clatters away into the dark. A miss.")
    @arrows -= 1

    # The shot startles the Wumpus; it may shamble into an adjacent room.
    if wumpus_stirs
      say w("TSK TSK TSK - WUMPUS GOT YOU!",
        "{red-fg}{bold}The noise wakes the Wumpus and it stumbles into your room. It eats you!{/}")
      lose
      return
    end

    if @arrows <= 0
      say w("YOU ARE OUT OF ARROWS",
        "{red-fg}{bold}You've run out of arrows. The Wumpus will get you eventually…{/}")
      lose
      return
    end

    gap
    describe_room
  end

  # ---- Endgame ---------------------------------------------------------------

  private def win
    # The original's taunt; modern mode's "You win!" (printed in shoot) suffices.
    say "HEE HEE HEE - THE WUMPUS'LL GET YOU NEXT TIME!!" if mesg?
    end_prompt
  end

  private def lose
    say "HA HA HA - YOU LOSE!" if mesg?
    # @prev_wumpus (the Wumpus's room at the start of this turn), not @wumpus: a
    # stir can move it onto you in the same turn, which would otherwise reveal
    # your own room instead of where the Wumpus had been lurking.
    say w("THE WUMPUS WAS IN ROOM #{@prev_wumpus}", "The Wumpus was in room #{@prev_wumpus}.") if reveal?
    end_prompt
  end

  # After a game ends: with "same" on, ask "SAME SET-UP (Y-N)?" and wait;
  # otherwise start a fresh game immediately.
  private def end_prompt
    if same?
      @awaiting_replay = true
      say "SAME SET-UP (Y-N)?"
    else
      new_game
    end
  end
end

opt = Wumpus::PRESETS["2026"].dup
ARGV.each { |arg| Wumpus.apply_arg(opt, arg) }

Wumpus.new(opt).run
