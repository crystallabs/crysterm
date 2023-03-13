# TODOs, Most Important First

## Immediate Source Code TODOs

- Open src/namespace.cr. In there is code for initializing `Style`. Use that example to introduce `def x(@y = undefined)`, where `undefined` would be macro that expands to default value of that property

- Oversized widgets issue (small-tests/checkbox.cr)
- Misplaced cursor issue (small-tests/radiobutton.cr)

- When first/default widget is focused, the cursor does not render in it (e.g. small-tests/focus.cr)

- In small-tests/focus.cr, why the box with instructions is getting focused even though it has `keys: false` and messes up focusing

- In small-tests/question.cr, see if the widget can be fixed to work properly, or it's not worth it (since the original implementation of the widget in Blessed is quite weird, maybe it should be redone)

- Fix rendering of cursor color. Appears to be ignored in some cases.

- Fix artificial cursor blink

- Fix for TextArea's _done; make sure that both examples/hello2.cr and prompt/question example work

- When one presses Shift/ShiftTab to navigate between widgets, the cursor shows up. This happens in Blessed too. But, (1) is this desired/expected behavior?, and (2) if yes, the cursor does not show up initially when focus is set programmatically -- why?

- In Checkbox and Radiobutton widgets, when these elements have a border or padding, the cursor is placed incorrectly because it is hardcoded that it goes to relative position 0,1. This is a bug present in blessed too.

- Make sure that chars typed in text input are immediately rendered (i.e. not holding 1 in buffer in non-release mode). Hopefully the only issue here is just timing, i.e. the way how render() call schedules a render.

- Issue with transparency, where a transparent element gets more opaque on every render. This is caused by code found at first occurrence of 'transparency' in src/widget.cr. Example can be seen if we add a transparent padding to e.g. members list widget in example/chat.cr. In Blessed, the value of lines[y][x][attr] seems to always be the same, whereas in our case it has the resulting value from previous render, and so on every render the field's color gets additionally blended until it has 100% opacity rather than staying at initial/desired value.

- On exit, reset colors and exit from ACS

- Resizing doesn't work 100% right - some resizing artifacts remain as one is resizing around. Or it seems it works?

- Maybe add a GUI-dedicated thread like in Qt?

## Non-critical Fixes and Small Improvements to Existing code

- When `Display` is created, if `TERM` env var is not defined it defaults to `xterm` or `windows-ansi`. Make this more robust to also include the existing check for which terminal emulator is in use, and then use the default which matches the default term setting of that emulator.

- For `OptimizationFlag`s listed in src/namespace.cr, make a list of all common terminal emulators and see which one support which optimizations. Than make default optimizations turn on/off based on that (unless overriden by user).

- Screen#screenshot method remains to be ported over

- When label widget is created on a widget, value of parse_tags is inherited from parent. Not sure if that's the best approach.

- Determine what is the exact current situation re. whether borders/angles are drawn using ACS chars or Unicode chars?

- Add support for graphemes when the patch gets merged into Crystal

- Same as Widget#hidden, rename Cursor#_hidden

- Determine what to do with label.side

- Make cursor be property on widget

- Allow Displays to have Screens as children elements (to allow screens being present in multiple windows). Or just dup them?

- Make Widget#content be original, user-supplied content. Name all other accessors differently (same type of solution as for left/right/etc.)

- If the screen is too small to display a widget in layout, don't hide it completely, make sure that at least something is drawn even if incomplete or incorrect. See e.g. misc/pine.cr for an example

- When aligning widgets, see if it is possible to control what char will fill the empty space, instead of always ' '

- Verify color names specifically listed in tput's `src/tput/output/text.cr` and check if there are any discrepancies compared to color names or name syntax and pattern listed/supported in the `term_colors` shard. If yes, make them uniform.

- Widget::Prompt - determine the reason for 1 cell difference in positioning of "Question" and "Cancel". Does it have to do with auto_padding which is now default? If yes, just ignore this issue.

- Crysterm is missing a full, 100% working TextArea widget (same as Blessed). TextArea that exists is very basic. Dbkaplun wrote Slap, text editor based on blessed. Try to port its text editor widget to Crysterm

- Add the top of `def _render`, there is code added checking for _is_list etc., to be able to style list items correctly. But, this probably needs to go into a render() function which is subclassed in List, rather than being present in global _render

- Make sure that the background character for a cell is always configurable and never literally taken to be ' '.  This will allow someone to completely change what the background char is. I guess this has already been done to a good extent, but verifying/confirming it would be good.

- Make uniform passing of args to classes, with class decls, function arguments, and arg.try... (E.g. disable unnamed parameters to all methods that have non-trivial args)

- It is not 100% defined what happens if a Widget has parse_tags true, and there is syntax error in the tags. A syntax error is something as simple or just { or }. In the case of one {, { remains in input and the rest is removed. In all other cases (more {s or one or more }s), the whole section is removed.  This should be fixed/standardized. Offhand, either always removing everything, or always removing anything that's invalid as-is. (Didn't check yet how blessed does it.)

- In the code, things to change/improve are identified with "TODO".

- In Blessed code (and inherited in Crysterm code), checks for borders are made in a very simple way. E.g. `if @border`, then the widget is reduced by 1 cell on every side, to account for border. It would be good to specifically check for border on each side, and also possibly to also support borders of different widths.

- Currently, default events in widgets are implemented in instance vars, and then when we want to enable/disable widget events, we either add or remove those handlers/vars from the events' handlers hashes. But the code for that is tedious/almost manual. Maybe all events should be in an array or something, and then adding or removing is just handlers.clear or handlers.push *array.

- Adding TrueColor support

## Would be Good to Add

- Evaluate when events are triggered and how they are named. Events that are triggered before the code is executed should be named like e.g. 'Attach'. Events that trigger after the work has been done should be in past tense, e.g. 'Attached'.

- There now exists default style in `Crysterm::Style.default`. See how this could be used. Does it apply to all widgets or only those without a parent set? If the latter, then other widgets could inherit style from parent. Does this happen via explicit reference or lookup in code? If explicitly, then we should also remove the style when widget is removed from parent.

- Style setting for determining whether cursor is visible in a widget or not. E.g. it should be possible to have cursor optionally appear in focused checkboxes and radiobuttons.

- Review the current model how Widget's `property style : Style` works and do whatever is necessary to have the most automatic, streamlined, and working style in default scenarios, as well as design it such that complete theming can be from from YAML/JSON

- See if it would make sense to name/rename all EventHandler events in such a way that the name identifies whether the action is about to happen, or has happened. In that case, e.g. Event::Render would mean the event has been triggered before the actual action, and Event::Rendered would mean it was triggered after.

- Implement artificial cursor (with cursorFlashTime option). See how it's done in Blessed.

- Make all widgets able to have their own cursor type when they're in focus. Currently I think cursor is the same for all widgets on a screen; there is no automatic changing of it based on focus and widget's settings.

- See that whatever widgets have done on initialize are undo-ed when they or Screen they were on are destroyed

- Support "Alternate" style in Style. There should be code which gives the "opposite" of any color. Then in code, when we detect overlapping colors which are too similar, one can simply be switched to its opposite. Minimal/beginning for this might be in existence. Search for "invert" and "attr".

- Qt-style MenuActions

- All other Qt features :)

- More widgets - from Blessed and `slap` text editor based on Blessed

- Add max len to text widgets

## Things to Investigate

- Profile the app: `build --debug; perf record --call-graph dwarf ./app; hotspot perf.data`

- In Blessed, there are a couple _isX variables. They can be replaced with #is_a?(Class) in Crysterm, and that has been done in some places. But, this might make users unable to set _is_x in their own widgets, if they don't want to inherit from List etc. See if _is_x are actually better than is_a?s. Or figure out how someone would get e.g. _is_list behavior from Crysterm's core without inheriting from List.

- In TextArea widget, arrows can be used for scrolling and it works correctly (even though the behavior is a little bit unintuitive). All this is inherited from Blessed. The unintuitive part is that the cursor position isn't reflected when using the arrows, so it's not clear that scrolling will eventually happen. Also positioning the cursor within existing text doesn't work because cursor can't move. An attempt to make it move just as a scrolling indicator was made, and it almost worked (see `to_scroll_pos` in TextArea). But the scroll pos is then hidden/reverted by code in Widget which calls _update_cursor() on widget that is in focus. See if this can be fixed to really work.

- In Crysterm, which should aim to be fully OO & clean code, strings have been replaced with enum values in many places. However, when specifying widget sizes or position, percentages are still typically given with strings, e.g. "80%", top/left support a special string value of "center", and width/height support "resizable". Strings can stay as a supported option (for convenience of loading settings from text files, etc.?), but see if those can be replaced with enums or similar, and with things like 80.percent() or something.

- For good OO, and like in Qt, it would be good if all functions that deal with Points, Sizes, and Dimensions, would also accept those specific classes/structs that we'd define, rather than just numbers/Ints. This already exists to an extent, e.g. in Tput there is class Size, Point, etc. These should be used more throughout the codebase, and any other relevant new ones added.

- src/widget/overlayimage.cr -> is that OK or more work needs to be done?

- src/widget/question.cr -> needs more work (check why it breaks with padding: 1)

- Would anything be gained by using a Set instead of an Array as the containing element for individual Cell's which represent all chars/cells on the screen?

- Performance improvements - can something substantial be done? In widgets and everywhere, but specifically:
(1) for draw() - would it help if there was a region to draw manually managed, or current do-all code is fine?
(2) for render/draw - any benefit from draw() being separately schedulable? Also, how to keep track of rendering and skip it if nothing has changed? And where in memory is rendering? in screen or in widget?
(3) Can parse_content be called less times, and can `if @parse_tags` be checked less times?

- Implement generic functions for all size/position values. Right now, top/left/width/height etc. can take various specifications, including "center", "resizable", "80%" etc. It would be good to completely streamline this, so that value can be set using all these options, but when reading it (e.g. through special getters) they would always return an int value if possible, and nothing else.

- Currently, one can set widget's content with "content: ...". However, the code manipulates this value on its own. And therefore text widgets have a custom "text" where the raw/user value is. See if it's possible that @content is never re-set to parsed/internal value, and that it always contains direct/raw user input. If possible, then @text hacks wouldn't be needed.

- When drawing to screen, @ret variable can be used for diverting output temporarily. See if, instead of that method which was inherited from blessed, it could be a block that yields and writes to given IO.

- Check if there if performance benefit to manually checking if there are event listeners before emitting events. We currently do this, but if the speed is the same, then we shouldn't bother checking in advance, but we should simply emit always.

- When specifying top/left, it is possible to say "center". This will center the widget, and is different than saying "50%". For example, for a screen of 100 and width 50, "center" will make it begin at 25, while "50%" will make it begin at 50. Now, when using percentages, it is possible to say e.g. "50%+10" (This would result in widget starting at 60 in our example). But it appears it is not possible to use the +- specifier if "center" is used. Support specifying +- in all cases.

- In the code, questions and/or things to verify at some later point are identified with "XXX".

- Potentially move content-related helpers from `src/helpers.cr` into `src/widget_content.cr`

- See how much `src/screen_children.cr` is really different from `src/mixin/children.cr`, and if possible make `Screen` use this mixin for more functionality with less code

## Theoretical Discussion / Tasks

Most of these can be ignored, they are highly contextual.

- After commits of May 28, for some reason Layouts (maybe other widgets?) don't behave as they did. Specifically for Layouts, Layouts now need width/height where previously this wasn't needed. (Maybe screen's append function doesn't do all it should?)

- Currently, when a Screen is listening for keyboard, it does this keypress by keypress. See how this affects pasting blocks of text into the terminal via mouse. Maybe they could be a "batch" mode where, if a paste is detected (possibly by realizing that multiple bytes became available at the same time?), all this text is processed as a plain text, at once? Maybe with a flag/toggle to do so?

- Currently events are emitted where ever needed with just e.g.: `emit SomeEvent, ...`.  See if this is OK, or if events to emit should be passed via a channel and always be emitted from a single/same Fiber.

- Examine effect of `use_buffer` variable in Tput, and see whether it can be completely removed, or it can be used meaningfully in some way?

- See if it would be of any benefit to mark certain methods with @[AlwaysInline].

- In rendering, there is Overflow enum used as a return type, which defines what to do if a widget can't be rendered without overflowing. Add MoveWidget or similar as another option. It would have the effect of moving the widget so it can render. A use case for this would be e.g. auto-completion boxes or similar which pop-up. For simplicity the developer would just have them pop up at the desired location, and Crysterm would adjust for overflow automatically.

- When dealing with colors, do we want #aabbcc to be some class/struct, or just String is OK?
