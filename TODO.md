# TODOs, Most Important First

## Immediate Source Code TODOs

- Make sure that chars typed in text input are immediately rendered (i.e. not holding 1 in buffer)

- Issue with transparency, where a transparent element gets more opaque on every render. This is caused by code found at first occurrence of 'transparency' in src/widget.cr

- On exit, reset colors and exit from ACS

- Resizing doesn't work 100% right - some resizing artifacts remain as one is resizing around

## Fixes to Existing Code

## Non-critical Fixes / Small Improvements to Existing code

- Verify color names specifically listed in tput's `src/tput/output/text.cr` and check if there are any discrepancies compared to color names or name syntax and pattern listed/supported in the `term_colors` shard. If yes, make them uniform.

- Ability for scrollbar to be on the left side of the widget

- Widget::Prompt - determine the reason for 1 cell difference in positioning of "Question" and "Cancel". Does it have to do with auto_padding which is now default? If yes, just ignore this issue.

- If at all possible, make widgets instantiable without `screen:` value. Currently screen is needed because some things re. widgets are looked up in their `#screen`. Would be great if nothing in widget code would touch `screen` unless widget really was a child of particular screen. This would also make widgets migratable between screens, which currently (inherited from Blessed) is not possible.

- Crysterm (inherited from Blessed) is missing a full, 100% working TextArea widget. TextArea that exists is very basic. Dbkaplun wrote Slap, text editor based on blessed. Try to port its text editor widget to Crysterm

- Add mouse support
- Add the top of `def _render`, there is code added checking for _is_list etc., to be able to style list items correctly. But, this probably needs to go into a render() function which is subclassed in List, rather than being present in global _render

- Make sure that the background character for a cell is always configurable and never literally taken to be ' '.  This will allow someone to completely change what the background char is. I guess this has already been done to a good extent, but verifying/confirming it would be good.

- Make uniform passing of args to classes, with class decls, function arguments, and arg.try... (E.g. disable unnamed parameters to all methods that have non-trivial args)

- There is a concept of Unicode and "full Unicode". Full being the one with all Unicode stuff that Crystal currently does not support outside of its UTF-8 support. See what to do this over time - is there a chance Crystal would support more? Yes:
https://github.com/crystal-lang/crystal/pull/10721#

- Regarding "label" on widgets, option `side` can't be passed at the moment. Could turn it into a class or enum, and see how side would be passed embedded in `Widget#initialize`'s `label` argument

- Widget's option `label:` creates a text widget behind the scenes. Maybe this option should be renamed label_text: or similar, and label should allow providing a complete Widget in this place.

- It is not 100% defined what happens if a Widget has parse_tags true, and there is syntax error in the tags. A syntax error is something as simple or just { or }. In the case of one {, { remains in input and the rest is removed. In all other cases (more {s or one or more }s), the whole section is removed.  This should be fixed/standardized. Offhand, either always removing everything, or always removing anything that's invalid as-is. (Didn't check yet how blessed does it.)

- In the code, things to change/improve are identified with "TODO".

- In Blessed code (and inherited in Crysterm code), checks for borders are made in a very simple way. E.g. `if @border`, then the widget is reduced by 1 cell on every side, to account for border. It would be good to specifically check for border on each side, and also possibly to also support borders of different widths.

## Would be Good to Add

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

## Theoretical Discussion / Tasks

Most of these can be ignored, they are highly contextual.

- After commits of May 28, for some reason Layouts (maybe other widgets?) don't behave as they did. Specifically for Layouts, Layouts now need width/height where previously this wasn't needed. (Maybe screen's append function doesn't do all it should?)

- Currently, when a Screen is listening for keyboard, it does this keypress by keypress. See how this affects pasting blocks of text into the terminal via mouse. Maybe they could be a "batch" mode where, if a paste is detected (possibly by realizing that multiple bytes became available at the same time?), all this text is processed as a plain text, at once? Maybe with a flag/toggle to do so?

- Currently events are emitted where ever needed with just e.g.: `emit SomeEvent, ...`.  See if this is OK, or if events to emit should be passed via a channel and always be emitted from a single/same Fiber.

- Examine effect of `use_buffer` variable in Tput, and see whether it can be completely removed, or it can be used meaningfully in some way?

- On an element, top/left/width/height can also be a string. Also allow Symbols to be used?

- See if it would be of any benefit to mark certain methods with @[AlwaysInline].

- In rendering, there is Overflow enum used as a return type, which defines what to do if a widget can't be rendered without overflowing. Add MoveWidget or similar as another option. It would have the effect of moving the widget so it can render. A use case for this would be e.g. auto-completion boxes or similar which pop-up. For simplicity the developer would just have them pop up at the desired location, and Crysterm would adjust for overflow automatically.

- When dealing with colors, do we want #aabbcc to be some class/struct, or just String is OK?
