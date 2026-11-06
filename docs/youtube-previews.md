# YouTube previews

`PaperThumb` recognizes YouTube watch, short, live, embed, music, and youtu.be links. It picks a random still from the highest-resolution public storyboard level, excluding the opening and closing 5% when enough frames are available. Only the selected small storyboard sheet is fetched; no video playback, video download, cookies, or Papery credentials are involved in requests to YouTube.

The random selection stays stable while that preview is visible. A new preview can choose another frame, including when a video returns in the standby bookmark rotation. The complete video frame fits inside the existing preview area. This applies to Papery rows, Curius long-press previews, and both standby layouts through the shared component.

If a storyboard is absent or unavailable, the loader tries one of YouTube's three numbered video stills. If those also fail, the usual Papery page preview remains the final fallback. Metadata expires after 15 minutes (failed lookups after two minutes); decoded sheets and preview images have bounded memory caches. Cancelled views do not publish stale images or start fallback requests.

The public storyboard format and numbered still variants are also handled in [yt-dlp's YouTube extractor](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_video.py). YouTube can change this format; parsing and image failures fall back rather than blocking the reading list.

Validation:

```sh
swiftc Wooper/Services/YouTubePreview.swift tests/YouTubePreviewTests.swift -o /tmp/youtube-preview-tests
/tmp/youtube-preview-tests
/tmp/youtube-preview-tests --live
```

The live check fetches two distinct frames from the public Big Buck Bunny sample and writes `/tmp/youtube-preview-0.png` and `/tmp/youtube-preview-1.png` for visual inspection. Offline checks cover supported and invalid URLs, JSON escaping, storyboard levels/signatures, partial final sheets, crop pixels/bounds, and fallback selection.
