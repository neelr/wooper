# In-app browser and web ink

HTTP(S) links opened through the app's `openURL` environment or delivered from a widget now open a full-screen `WKWebView`. Papery, Curius, recording links, and standby bookmarks share this route. Browser presentation prevents standby from starting. A linked page or a new-window link stays in the same browser; history swipe navigation remains available.

Annotations and their controls appear only with regular horizontal and vertical size classes, including the Duo's expanded screen. The outside screen remains an ordinary responsive browser. On expansion, the page returns to the saved annotation width and restores the ink.

A floating horizontal Liquid Glass palette at the top left alongside the status indicators offers scroll, pen, highlighter, and stroke eraser, with PencilKit rendering the ink. There is no title bar or bottom toolbar; a small bottom-left arrow returns to Papery. Two-finger taps undo and three-finger taps redo, with equivalent accessibility actions on the palette. History taps are disabled on the outside screen and cannot interrupt an active Pencil stroke.

Each browser starts in scroll mode: Pencil drags scroll immediately and short taps reach website links. Holding the tip still for 0.3 seconds toggles between scrolling and drawing, confirms with a haptic and selected tool, and retains that mode after the Pencil lifts. A hold toggles only once, leaves no dot, and allows subsequent movement in the same contact to use the new mode. The hand button selects scrolling; choosing an ink tool selects drawing. A small initial ink mark within 24 points is provisional: holding removes it before switching to scroll, without a jump or an undo step. Pauses during longer handwriting or an already-moving scroll cannot switch modes. Fingers normally interact with the website. There is no overflow menu on either screen.

The Duo supplies Pencil touch types after the initial hit test. A typed gesture recognizer on the common parent therefore captures coalesced Pencil positions, pressure, and tilt, and renders them as PencilKit strokes. The ink canvas never blocks website hit testing. Erasing removes intersected strokes; each completed contact is one undo step. The drawing preview follows input immediately and is saved when the stroke finishes.

While the Pencil touches or hovers over the page, palm rejection pauses native finger scrolling and stops any ongoing finger flick. A passive observer tracks both touch types together. Hands already resting on the screen, or arriving during the 0.45-second grace period between strokes, stay rejected until lifted. Pencil hold-to-scroll still moves the page directly. Normal finger scrolling returns after the Pencil and resting hand leave; folding into small-screen browsing clears the protection. Hover protection is used when the hardware reports it.

Pen footprints have a three-point minimum so light pressure remains visible in PencilKit. Previously saved thinner pen marks are repaired when loaded, preserving their positions and leaving highlighter strokes unchanged. Provisional strokes are excluded from autosave until committed.

The transparent canvas follows the web scroll view's offset, content size, and zoom scale. Drawings stay in document coordinates. Each annotated URL retains its original expanded layout width; the expanded viewport scales this layout rather than reflowing it. This is a live browser, not an archived copy: a publisher changing content, an inserted ad, or other dynamic layout changes can still move content relative to existing ink.

Ink autosaves after changes and flushes before navigation, closing, folding, and backgrounding. Local files live in Application Support/WebAnnotations with SHA-256 filenames, atomic writes, and versioned records containing the document URL, width, PencilKit drawing, and update date. Ordinary URL fragments share a drawing; query strings and hash-router paths remain distinct. Save failures are visible and prevent ordinary navigation/closing from discarding the drawing. Failed reads leave the original file intact. Annotations are device-local, with no new server or credential use.

Core checks:

```sh
swiftc Wooper/Browser/WebAnnotationStore.swift Wooper/Browser/PencilPalmRejection.swift tests/WebAnnotationTests.swift -o /tmp/wooper-web-annotation-tests
/tmp/wooper-web-annotation-tests
```

`scripts/test-web-browser.sh` also builds a small simulator host from the production browser sources and checks first-page loading, saved ink reopening, document-coordinate scrolling, compact visibility, restored expanded width, and finger passthrough. It defaults to the iPad Pro 13-inch (M5) simulator; set `BROWSER_TEST_DESTINATION` to use another installed simulator.

Device checks: open an article from Papery and Curius, scroll immediately with the Pencil, hold to select drawing, lift and make several strokes, then hold again to return to scrolling, tap a website link with a finger, go back, close/reopen the browser, and relaunch the app. Fold to the outside display and confirm the ink and tools disappear; expand again and confirm alignment. Confirm standby stays off while reading. Actual Pencil timing and Duo transitions need physical-device verification.
