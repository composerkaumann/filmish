# Filmish

A personal native macOS SwiftUI front end for the frame-accurate
`filmish.sh` FFmpeg workflow. Technically a movie, probably.

Version 1.2 sorts images alphabetically, checks every image dimension, supports
24/25/30 fps, and gives every image boundary its own FFmpeg transition type and
decimal-second duration. All times are rounded internally to the nearest video
frame. **Use the same fade between all images** links the row controls so one
edit updates them all; turning it off allows individual fades. Fade-in from
black, fade-out to black, and between-image fades default to 1.0 seconds.
All enabled fades occupy their own part of the fixed total timeline and are
therefore excluded from the images' clear display times.

Each image also has an optional **Clear Display** time, which does not include
its fades. Leave it blank for Auto; the app distributes the remaining timeline
across all Auto images and shows the calculated actual clear time beside every
image. Fixed times that cannot fit produce an error before rendering.

The image list includes thumbnails and supports drag-and-drop playback order.
Rescanning preserves the custom order and appends newly discovered images;
it also preserves individual fade settings. **Reset to Alphabetical** restores
natural filename order. Each row also has a **Remove** button that excludes the
image from the current slideshow without deleting the original file.

Keyboard Tab and Shift-Tab move through the editable time fields in their
visible order, including transition and clear-display times in every image row.

## Versioning

Every new user-facing packaged `Filmish.app` build increments the third version
component: `1.2.1`, `1.2.2`, and so on. Test builds and intermediate compiles do
not change the version. When a new base version is explicitly declared, such as
`1.3`, that release uses `1.3` and subsequent packaged builds continue with
`1.3.1`, `1.3.2`, and so on. `CFBundleVersion` also increments for every
user-facing packaged build.

## Build the app

```bash
./Packaging/package_app.sh
```

The signed development build is created at `dist/Filmish.app`.
The packaging script generates the complete macOS `AppIcon.icns` from
`Assets/AppIcon.png` and embeds it in the app bundle.

The app expects Homebrew FFmpeg at `/opt/homebrew/bin/ffmpeg` and
`/opt/homebrew/bin/ffprobe`, with `/usr/local/bin` as a fallback.

Install FFmpeg on a new Mac before running the app:

```bash
brew install ffmpeg
```

At launch, the app checks for both `ffmpeg` and `ffprobe`. If either tool is
missing, it shows the command above, links to the official Homebrew and FFmpeg
formula pages, disables rendering, and provides a **Check Again** button. The
terminal script performs the same check and prints the installation steps
before exiting.
