require "../../../src/crysterm"

class Wumpus
  include Crysterm

  private def help
    say "
A faithful little port of Gregory Yob's 1973 classic, built in Crysterm.
You explore a fixed cave of 20 rooms laid out as a dodecahedrony (every
room connects to three others, always the same) hunting the Wumpus.
You can't see it. Entering his room or shooting from nearby make him wake
up and eat you or move 1 room. Try deduce its location from warnings in
adjacent rooms, then fire a \"crooked arrow\" to shoot it. Arrows can veer
through up to 5 rooms, but you must give room numbers.

{bold}Hazards{/}:
  * The Wumpus     - shoot it to win; bump into it and it eats you.
  * Bottomless pits- fall in and you're gone.
  * Super bats     - pick you up and drop you in a random room.
  * Arrows         - you have a limited number; may kill you.
The Wumpus can move and stay in a room with bats or a pit. You cannot.

{bold}Commands in current config (type, then press Enter):{/}"

    if prompts?
      say "  m, then WHERE TO?            answer with a room number to move"
      say "  s, then NO. OF ROOMS (1-5)?  then a ROOM # for each, to shoot"
    else
      say "  <room>           move to an adjacent room (e.g. 5)"
      say "  m <room>         move to an adjacent room (space optional: m5)"
      say "  s <room> [room…] shoot up to 5 rooms; any delimiter (s 13/12+3,2)"
    end
    say "  b                go back to previous room"
    say "  n                start a new game"
    say "  h or ?           help (show current preset and flags)"
    say "  q                quit (also Ctrl-Q)"
    say
    say "{bold}Current flags (type name to toggle, +-name to set):{/}"
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

  # Dodecahedron map from the original game. Room N (1-based) connects to the
  # three rooms listed.
  MAP = {
    1 => {2, 5, 8}, 2 => {1, 3, 10}, 3 => {2, 4, 12}, 4 => {3, 5, 14},
    5 => {1, 4, 6}, 6 => {5, 7, 15}, 7 => {6, 8, 17}, 8 => {1, 7, 11},
    9 => {10, 12, 19}, 10 => {2, 9, 11}, 11 => {8, 10, 20}, 12 => {3, 9, 13},
    13 => {12, 14, 18}, 14 => {4, 13, 15}, 15 => {6, 14, 16}, 16 => {15, 17, 18},
    17 => {7, 16, 20}, 18 => {13, 16, 19}, 19 => {9, 18, 20}, 20 => {11, 17, 19},
  }

  STARTING_ARROWS = 5

  # Every difference between the flavors, as an independent on/off flag.
  FLAGS = %w[mesg prompts bump crooked same back reveal gap score wimpus]

  # One-line description of each flag, for the help screen.
  FLAG_HELP = {
    "mesg"    => "original and ALL-CAPS messages (off = modern, colorized)",
    "prompts" => "original longer/slower prompts",
    "bump"    => "bump the Wumpus only wakes it (off = sure loss, on = 25% loss)",
    "crooked" => "allow a shot that doubles back, A->B->A (off = no)",
    "same"    => "ask SAME SET-UP? to replay cave (off = new positions)",
    "back"    => "enable 'b' for step-back command",
    "reveal"  => "reveal the Wumpus's room after loss",
    "gap"     => "teletype blank-line spacing (off = compact)",
    "score"   => "running scoreboard pinned top-right (off = hidden)",
    "wimpus"  => "Wumpus suffers bats & pits too (off = immune)",
  }

  # Named groups of flag settings. The default pack is the first key.
  PRESETS = {
    "1973" => {"mesg" => true, "prompts" => true, "bump" => true, "crooked" => false,
               "same" => true, "back" => false, "reveal" => false, "gap" => true, "score" => false,
               "wimpus" => false},
    "2026" => {"mesg" => false, "prompts" => false, "bump" => false, "crooked" => true,
               "same" => false, "back" => true, "reveal" => true, "gap" => false, "score" => true,
               "wimpus" => true},
  }

  # Grammatical forms of whoever a hazard message is about, so the same bat/pit
  # wording serves both the player and (with "wimpus" on) the Wumpus. See
  # bat_snatch_msg / pit_msg.
  PLAYER = {caps: "YOU", name: "you", subj: "You", obj: "you", verb_s: ""}
  WUMPUS = {caps: "THE WUMPUS", name: "the Wumpus", subj: "The Wumpus", obj: "it", verb_s: "s"}

  @player = 1
  @prev_player = 1 # room occupied before the current one (for the "back" flag)
  @wumpus = 1
  @prev_wumpus = 1 # Wumpus's room at the start of the current turn (for the loss reveal)
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

  # Whether any game has started yet, so new_game separates each fresh prolog
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

  # Running scoreboard (the "score" flag). Tallies persist across games:
  #   player - +1 each win: you shoot the Wumpus, or ("wimpus" on) it falls in a pit
  #   wumpus - +1 each time it eats you
  #   holes  - +1 each time you fall into a pit
  #   bats   - +1 each time bats drop you straight into a pit
  #   arrows - +1 when your own arrow skewers you, or you run out and die
  @score_player = 0
  @score_wumpus = 0
  @score_holes = 0
  @score_bats = 0
  @score_arrows = 0

  def initialize(@opt : Hash(String, Bool))
    @screen = Window.new title: "Hunt the Wumpus"

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
      # Yellow text field, but give the border its own dark background/white
      # rule so it blends into the surrounding chrome (matching the transcript
      # box above) instead of drawing a stark yellow frame.
      style: Style.new(fg: "black", bg: "#e0e000",
        border: Border.new(bg: "#1a1a2e", fg: "white"))

    # Scoreboard: a small titled box pinned to the top-right corner, inside the
    # transcript's outer border. Shown only when "score" is on (see
    # update_score). Overlays the transcript, whose scroll bar shares this
    # column once the log scrolls; `z-index: 10` floats the box above that bar
    # (theme puts the bar on plane 5) so its right border isn't eaten. See the
    # theme's `.popup`/`Menu` overlays for the same pattern.
    @scorebox = Widget::GroupBox.new \
      top: 1,
      right: 1,
      width: 15,
      height: 7,
      title: " Score ",
      parse_tags: true,
      style: Style.new(fg: "white", bg: "#16213e", border: true, margin: :right)
    @scorebox.style.z_index = 10

    @screen.append @transcript
    @screen.append @input
    @screen.append @scorebox
    @input.focus

    @input.on(Event::Submit) do |e|
      text = e.value.to_s.strip
      if text.empty?
        # Enter on an empty line re-prints the current status: the room
        # description, or whichever teletype prompt we're waiting on.
        repeat_status
      else
        # Echo the typed line into the transcript so it stays in the scrollback
        # (like a real teletype). Braces are neutralized so user input can't be
        # mistaken for {tag} markup.
        say "> #{text.gsub('{', '(').gsub('}', ')')}"
        handle_command text
      end
      @input.value = ""
      @input.focus
      @screen.render
    end

    @screen.on(Event::KeyPress) do |e|
      if e.key == Tput::Key::CtrlQ
        @screen.destroy
        exit
      end

      # Keep typing effortless: a keystroke while focus has drifted off the
      # input box (e.g. after clicking into the transcript) grabs focus back and
      # still delivers that key, so you never have to click the box first. When
      # the box is already focused this is a no-op and the key flows normally.
      unless @input.focused?
        @input.focus
        @screen.emit_key @input, e
        e.accept
      end
    end
  end

  def run
    new_game
    @screen.exec
  end

  # ---- Flags -----------------------------------------------------------------

  # Give every flag a `<name>?` predicate that reads the live option, so call
  # sites read as `mesg?` rather than `@opt["mesg"]`. Generated from FLAGS so
  # the predicates can't drift from the flag list.
  {% for flag in @type.constant("FLAGS") %}
    private def {{flag.id}}?
      @opt[{{flag}}]
    end
  {% end %}

  # Pick original (1973) vs modern (2026) wording for a line, per the mesg flag.
  private def w(orig : String, modern : String) : String
    mesg? ? orig : modern
  end

  # Apply one configuration token to an options hash: a pack name ("1973"), a
  # bare flag name ("bump", toggles it), or a forced "+flag" / "-flag". Shared
  # by the command-line args at startup and typed input mid-game. Returns the
  # name of the single flag changed, "" for a preset, or nil if unrecognized.
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

  # Re-render the current room after a flag/preset change, in the new style.
  # Game state is untouched; a half-entered teletype prompt is abandoned since
  # the input model itself may have changed.
  private def refresh_options
    @input_state = :command
    update_score
    describe_room unless @awaiting_replay
  end

  # Current config as +flag/-flag tokens — exactly what you can type back to
  # set them (e.g. "+bump", "-reveal").
  private def options_line : String
    FLAGS.map { |f| "#{@opt[f] ? "+" : "-"}#{f}" }.join(" ")
  end

  # ---- Output helpers --------------------------------------------------------

  private def say(line : String = "")
    @transcript.push_line line
    @transcript.scroll_to @transcript.get_content.lines.size
  end

  # A blank separator line — kept when the "gap" flag is on (teletype spacing),
  # omitted when off (compact).
  private def gap
    say if gap?
  end

  # The "super bat snatch" notice for whoever got grabbed (player, or Wumpus
  # with "wimpus" on). `who` is PLAYER or WUMPUS.
  private def bat_snatch_msg(who) : String
    w("{magenta-fg}ZAP--SUPER BAT SNATCH! ELSEWHERE FOR #{who[:caps]}!{/}",
      "{magenta-fg}Super bats snatch #{who[:name]} and whisk #{who[:obj]} away!{/}")
  end

  # The "fell down a pit" notice, parameterized by subject (PLAYER or WUMPUS):
  # serves the player's death and the Wumpus's (which is your win).
  private def pit_msg(who) : String
    w("{yellow-fg}YYYIIIIEEEE . . . #{who[:caps]} FELL IN A PIT{/}",
      "{yellow-fg}{bold}#{who[:subj]} plummet#{who[:verb_s]} into a bottomless pit. Aaaaaa…{/}")
  end

  # ---- Scoreboard ------------------------------------------------------------

  # Inner width (inside the box border) used to right-align the scores.
  SCORE_WIDTH = 12

  # One scoreboard row: left-aligned colored label, right-aligned tally.
  # Padding is computed on the plain text so {tag} markup can't skew it.
  private def score_line(label : String, value : Int32, color : String) : String
    v = value.to_s
    pad = " " * (SCORE_WIDTH - label.size - v.size)
    "{#{color}-fg}#{label}{/}#{pad}#{v}"
  end

  # Refresh the scoreboard contents and toggle it with the "score" flag.
  private def update_score
    if score?
      @scorebox.content = [
        score_line("Player:", @score_player, "green"),
        score_line("Wumpus:", @score_wumpus, "red"),
        score_line("Holes:", @score_holes, "yellow"),
        score_line("Bats:", @score_bats, "magenta"),
        score_line("Arrows:", @score_arrows, "cyan"),
      ].join("\n")
      @scorebox.show
    else
      @scorebox.hide
    end
  end

  # The Wumpus has eaten the player (whatever path got it there): tally and show.
  private def score_wumpus_ate
    @score_wumpus += 1
    update_score
  end

  # ---- Game setup ------------------------------------------------------------

  private def new_game(reuse = false)
    if reuse
      # "SAME SET-UP": restore the exact starting cave.
      @player, @wumpus = @start_player, @start_wumpus
      @pits, @bats = @start_pits.dup, @start_bats.dup
    else
      # Place the player and hazards in six distinct rooms, remembering the
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

    say if @started # a blank line between games, but not above the very first
    @started = true
    if mesg?
      say "HUNT THE WUMPUS"
    else
      say "{bold}{yellow-fg}HUNT THE WUMPUS{/}"
      say "You enter a cave of 20 rooms. Somewhere a Wumpus sleeps."
      say "You carry #{@arrows} crooked arrows. Find it and shoot it."
    end
    say w("", "Type {bold}h{/} or {bold}?{/} for help.") # always shown
    gap
    update_score

    # With "wimpus" on, check the Wumpus's starting room against the cave's
    # hazards before the hunt begins: bats would relocate it, a pit wins outright.
    case wumpus_landing
    when :pit then wumpus_pit_win
    else           describe_room
    end
  end

  # ---- Per-turn description --------------------------------------------------

  private def describe_room
    tunnels = MAP[@player].to_a.sort
    adj = MAP[@player]
    smell = adj.includes?(@wumpus)
    draft = adj.any? { |r| @pits.includes?(r) }
    flap = adj.any? { |r| @bats.includes?(r) }

    if mesg?
      say "{red-fg}I SMELL A WUMPUS!{/}" if smell
      say "{yellow-fg}I FEEL A DRAFT{/}" if draft
      say "{magenta-fg}BATS NEARBY!{/}" if flap
      say "{green-fg}YOU ARE IN ROOM #{@player}{/}"
      say "TUNNELS LEAD TO #{tunnels.join(" ")}"
    else
      say "{red-fg}You smell a Wumpus!{/}" if smell
      say "{yellow-fg}You feel a cold draft.{/}" if draft
      say "{magenta-fg}You hear the flapping of bats.{/}" if flap
      say "You are in room {bold}#{@player}{/}. Tunnels lead to #{tunnels.join(", ")}. Arrows left: #{@arrows}."
    end

    # The teletype top-level prompt, independent of the wording flag.
    say "SHOOT OR MOVE (S-M)?" if prompts?
  end

  # Re-print the line the game is waiting on when the player presses Enter on
  # an empty input: the pending teletype prompt if mid-turn, the replay
  # question after a game ends, or otherwise the room status.
  private def repeat_status
    if @awaiting_replay
      say "SAME SET-UP (Y-N)?"
    elsif prompts? && @input_state != :command
      case @input_state
      when :move_target then say "WHERE TO?"
      when :shoot_count then say "NO. OF ROOMS (1-5)?"
      when :shoot_rooms then say "ROOM #?"
      end
    else
      describe_room
    end
  end

  # ---- Command dispatch ------------------------------------------------------

  # The room numbers from a shoot/move command's argument tokens, split so any
  # run of non-word characters (spaces, commas, etc.) delimits them ("3 12",
  # "3,12"). Non-numeric or out-of-range tokens are dropped.
  private def room_args(parts : Array(String)) : Array(Int32)
    parts[1..].join(" ").split(/\W+/, remove_empty: true).compact_map(&.to_i?)
  end

  # With "prompts" on, a turn walks the teletype sequence one Enter at a time
  # (see @input_state); otherwise a whole command is parsed per line.
  private def handle_command(cmd : String)
    return if cmd.empty?
    # Snapshot the Wumpus's room before resolving the turn: if it later stirs
    # onto you, the reveal still names where it *was*, not the room it died in
    # (now yours). See lose.
    @prev_wumpus = @wumpus
    parts = cmd.split(/\s+/)
    verb = parts[0].downcase
    # Let the shoot/move verb be glued onto its first room number ("s3", "m5"):
    # peel a leading s/m off when a digit follows. Rooms are pulled out with
    # room_args below.
    if g = verb.match(/\A([sm])(\d.*)\z/)
      verb = g[1]
      parts = [g[1], g[2]] + parts[1..]
    end

    # A pack name ("1973"), a bare flag ("bump", toggles it), or a forced
    # "+flag" / "-flag" reconfigures the game without resetting it, any time
    # (even mid-turn). For a single flag we echo its new state (+on/-off);
    # presets stay silent.
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
    when "where"
      # Undocumented peek: reveal every hazard's room (the Wumpus, pits, bats).
      say w("{red-fg}WUMPUS #{@wumpus}{/} - {yellow-fg}PITS #{@pits.sort.join(" ")}{/} - {magenta-fg}BATS #{@bats.sort.join(" ")}{/}",
        "Wumpus: {bold}#{@wumpus}{/}. Pits: #{@pits.sort.join(", ")}. Bats: #{@bats.sort.join(", ")}.")
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
      path = room_args(parts)
      if path.empty?
        say "Shoot where? e.g. {bold}s 3 12{/}"
      else
        shoot path
      end
    when "m", "move"
      if (room = room_args(parts).first?)
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

  # Handle one answer in the teletype prompt sequence, re-asking on bad input
  # just as the original did.
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
        # your room, so you can survive. With "wimpus" on, that shuffle can
        # carry it into a hazard too (see wumpus_stirs).
        say w("{red-fg}... OOPS! BUMPED A WUMPUS!{/}",
          "{red-fg}You blunder into the Wumpus — it wakes with a roar!{/}")
        case wumpus_stirs
        when :ate
          say w("{red-fg}TSK TSK TSK - WUMPUS GOT YOU!{/}",
            "{red-fg}{bold}It lunges and devours you!{/}")
          score_wumpus_ate
          lose
        when :pit
          wumpus_pit_win
        else
          gap
          describe_room
        end
      else
        say w("{red-fg}TSK TSK TSK - WUMPUS GOT YOU!{/}",
          "{red-fg}{bold}You walked right into the Wumpus! It gobbles you up.{/}")
        score_wumpus_ate
        lose
      end
      return
    end

    if @pits.includes?(@player)
      say pit_msg(PLAYER)
      @score_holes += 1
      update_score
      lose
      return
    end

    if @bats.includes?(@player)
      say bat_snatch_msg(PLAYER)
      @player = rand(1..20)
      # Credit the bats if they dropped you straight down a pit; the recursive
      # enter_room below still credits the hole itself.
      if @pits.includes?(@player)
        @score_bats += 1
        update_score
      end
      enter_room # might drop you somewhere nasty
      return
    end

    gap
    describe_room
  end

  # The Wumpus stirs after a shot or a bump: 75% chance it shuffles to a random
  # adjacent room. Returns its fate via wumpus_landing:
  #   :safe - nothing happened (still lurking somewhere harmless)
  #   :ate  - it ended up in your room (you're eaten)
  #   :pit  - it fell down a pit ("wimpus" on) — you win
  private def wumpus_stirs : Symbol
    @wumpus = MAP[@wumpus].to_a.sample if rand < 0.75
    wumpus_landing
  end

  # Work out what the Wumpus's current room means. Eaten if it's on you. With
  # "wimpus" on it also faces the cave's hazards: bats whisk it to a random
  # room (recursion re-checks), a pit swallows it (your win). Always announces
  # these events since the player can't otherwise see the Wumpus move.
  private def wumpus_landing : Symbol
    return :ate if @wumpus == @player
    return :safe unless wimpus?

    if @bats.includes?(@wumpus)
      say bat_snatch_msg(WUMPUS)
      @wumpus = rand(1..20)
      return wumpus_landing
    end

    return :pit if @pits.includes?(@wumpus)
    :safe
  end

  # The Wumpus fell down a pit (only with "wimpus" on): announce it, tally the
  # win, and end the game.
  private def wumpus_pit_win
    say pit_msg(WUMPUS)
    @score_player += 1
    update_score
    win
  end

  # ---- Shooting --------------------------------------------------------------

  private def shoot(path : Array(Int32))
    if path.size > 5
      say w("NO. OF ROOMS (1-5)?", "An arrow can only fly through 5 rooms.")
      return
    end

    # Unless "crooked" is on, the arrow can't double back on itself: no room
    # may equal the one two steps earlier in the path (A -> B -> A).
    unless crooked?
      (2...path.size).each do |i|
        if path[i] == path[i - 2]
          say w("{cyan-fg}ARROWS AREN'T THAT CROOKED - TRY ANOTHER ROOM{/}",
            "{cyan-fg}That shot would double back on itself — pick another room.{/}")
          return
        end
      end
    end

    # Trace the arrow's flight: a "crooked arrow" must turn between adjacent
    # rooms; naming a room it can't reach makes it veer off randomly.
    pos = @player
    path.each do |target|
      pos = if MAP[pos].includes?(target)
              target
            else
              MAP[pos].to_a.sample
            end

      if pos == @wumpus
        say w("{green-fg}AHA! YOU GOT THE WUMPUS!{/}",
          "{green-fg}{bold}Your arrow strikes the Wumpus! You win!{/}")
        @score_player += 1
        update_score
        win
        return
      end

      if pos == @player
        say w("{cyan-fg}OUCH! ARROW GOT YOU!{/}",
          "{cyan-fg}{bold}Your own arrow circles back and skewers you!{/}")
        @score_arrows += 1
        update_score
        lose
        return
      end
    end

    say w("{cyan-fg}MISSED{/}", "{cyan-fg}Your arrow clatters away into the dark. A miss.{/}")
    @arrows -= 1

    # The shot startles the Wumpus; it may shamble into an adjacent room, and
    # with "wimpus" on, into a hazard there.
    moved_from = @wumpus
    case wumpus_stirs
    when :ate
      say w("{red-fg}TSK TSK TSK - WUMPUS GOT YOU!{/}",
        "{red-fg}{bold}The noise wakes the Wumpus and it stumbles into your room. It eats you!{/}")
      score_wumpus_ate
      lose
      return
    when :pit
      wumpus_pit_win
      return
    end

    # It only grumbled off to a neighbouring room: in modern mode, note the move
    # (the only hint the player gets that the Wumpus shifted).
    say "{red-fg}Wumpus moves with a grumble.{/}" if !mesg? && @wumpus != moved_from

    if @arrows <= 0
      say w("{cyan-fg}YOU ARE OUT OF ARROWS{/}",
        "{cyan-fg}{bold}You've run out of arrows. The Wumpus will get you eventually…{/}")
      @score_arrows += 1
      update_score
      lose
      return
    end

    gap
    describe_room
  end

  # ---- Endgame ---------------------------------------------------------------

  private def win
    # The original's taunt; modern mode's "You win!" (printed in shoot) suffices.
    say "{red-fg}HEE HEE HEE - THE WUMPUS'LL GET YOU NEXT TIME!!{/}" if mesg?
    end_prompt
  end

  private def lose
    say "HA HA HA - YOU LOSE!" if mesg?
    # Uses @prev_wumpus, not @wumpus: a stir can move the Wumpus onto you in
    # the same turn, and the reveal should name where it *was*, not your room.
    end_prompt
  end

  # After a game ends: with "same" on, ask "SAME SET-UP (Y-N)?" and wait;
  # otherwise start a fresh game immediately.
  private def end_prompt
    say w("{red-fg}THE WUMPUS WAS IN ROOM #{@prev_wumpus}{/}", "The Wumpus was in room #{@prev_wumpus}.") if reveal?
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
