# In-app browser and web ink

HTTP(S) links opened through the app's `openURL` environment or delivered from a widget now open a full-screen `WKWebView`. Papery, Curius, recording links, and standby bookmarks share this route. Browser presentation prevents standby from starting. A linked page or a new-window link stays in the same browser; history swipe navigation, reload, and sharing are available.

Annotations and their controls appear only with regular horizontal and vertical size classes, including the Duo's expanded screen. The outside screen remains an ordinary responsive browser. On expansion, the page returns to the saved annotation width and restores the ink.

A floating vertical Liquid Glass palette centered on the left offers pen, highlighter, stroke eraser, and page options, with PencilKit rendering the ink. There is no title bar or bottom toolbar; a small bottom-left arrow returns to Papery. Two-finger taps undo and three-finger taps redo, with equivalent accessibility actions on the palette. History taps are disabled on the outside screen and cannot interrupt an active Pencil stroke. Quick Pencil movement draws. Holding the tip still for 0.3 seconds starts scrolling. A small initial mark within 24 points of the contact's start is provisional: holding removes it and switches to scrolling without a jump or an undo step. Larger handwriting stays ink when paused. Fingers normally interact with the website, including scrolling, links, and forms. “Draw with finger” is an optional browser menu setting; it uses the same quick-stroke/hold distinction.

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

Device checks: open an article from Papery and Curius, make a quick Pencil stroke, hold and drag to scroll, tap a website link with a finger, go back, close/reopen the browser, and relaunch the app. Fold to the outside display and confirm the ink and tools disappear; expand again and confirm alignment. Confirm standby stays off while reading. Actual Pencil timing and Duo transitions need physical-device verification.
