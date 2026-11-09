# On This Day

A native, private iOS photo time capsule, built with SwiftUI and PhotoKit. Requires iOS 18 or later and Xcode 26 or later (Swift 6.2+).

## Run

Open `OnThisDay.xcodeproj`, select the `OnThisDay` scheme and an iPhone simulator, and run. To run on your iPhone, select your signing team under Signing & Capabilities and choose your device. No backend or API keys are needed.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing the project specification, run `xcodegen generate`.

## Browse

- Allow photo access, either to your entire library or selected photos.
- Tap the share icon beside the photo counter to open the system share sheet. PhotoKit supplies the full-resolution current image (including saved edits), not the screen preview. iCloud downloads show progress and can be cancelled. Live Photos share as still images. The file can retain location and other metadata; the receiving app decides what to preserve. Sharing happens only after you choose an action in the system sheet; temporary exports are removed when it closes.
- Tap the left third of a photo to go back; tap the rest to advance. Horizontal swipes and explicit arrow buttons also work. Photos do not advance automatically or wrap at the ends.
- Swipe vertically between years with matching photos, newest first. Tap the year to jump directly to another year.
- Each year has segmented progress and a photo counter. For more than 20 photos, the progress indicator shows a sliding window of 20 segments.
- Pinch to zoom up to 5×, then drag to explore details. Double-tap while zoomed, or pinch back, to restore the fitted image before changing photos or years. Double-tap reset does not advance photos, and single-tap browsing at normal size stays immediate. Zooming requests a sharper image, capped at 4096 pixels on its longest target edge.
- The compact header combines the year, city, and date; photos use the full screen width. About is tucked inside the year menu.
- Photos with embedded GPS coordinates show a city in the center of the top bar when Apple reverse geocoding succeeds. Long names truncate without covering the year or date; VoiceOver reads the full name. The label hides while zoomed, leaving the photo unobstructed. Missing locations and lookup failures leave it hidden. Cached names appear synchronously with selection, without clearing the label or an artificial delay. The current location is resolved first, then the next/previous photo and the first photo of adjacent years are prefetched sequentially. Navigation cancels obsolete work. An in-memory cache keeps up to 100 cities; cold or failed lookups never delay showing the photo.
- Open the year menu → About to change permissions or toggle AI screenshot filtering. With limited access, only the photos you selected can appear.
- Manual hiding is no longer supported. Previously hidden memories are eligible again, subject to normal date, access, and screenshot filters. Photos hidden in the system Photos app remain excluded.

## Matching and privacy

PhotoKit metadata is scanned off the main actor, without decoding the library’s images. Photos match the current month and day in the Gregorian calendar and the device’s current time zone. The current year and future years are excluded; February 29 matches only February 29. Matching photos are ordered by capture date, with asset identifier as a stable tie-breaker.

Screenshots are excluded using `PHAssetMediaSubtype.photoScreenshot` and explicit screenshot filenames. The optional AI Screenshot Filter is on by default: Apple's on-device Vision classifier (`VNClassifyImageRequest`, revision 2, `screenshot` label) checks only today's matching candidates using 512-pixel target-size previews, one at a time, off the main actor. A confidence score of at least 0.9 excludes the image. This is an initial conservative cutoff, not a measured accuracy guarantee. Turn off the filter in About to recover AI-excluded photos. Videos and hidden library photos are not fetched. Live Photos display their still image.

Memories appear immediately after metadata matching; AI exclusions arrive incrementally while “Checking screenshots…” is visible. Scores are cached locally by asset identifier, modification date, and classifier revision. Unavailable previews, timeouts, unsupported classification, or inference failures keep the photo visible and can be retried. AI can miss screenshots or mistake photos for screenshots. Only local identifiers and scores are persisted, not image copies.

Images are requested at display resolution on demand. PhotoKit may download originals or previews from iCloud, including previews for screenshot checks; the app itself has no server, analytics, account, or upload functionality. Failed image requests can be retried. Library changes, permission changes, day changes, and significant system time changes refresh the index.

City lookup uses `MKReverseGeocodingRequest` on iOS 26+ and `CLGeocoder` on earlier releases. It sends coordinates from the current photo and nearby memories to Apple’s geocoding service, not the images. It does not request access to the device’s current location. City names use the English locale to match the app’s interface.

## Tests

Run Product → Test in Xcode, or:

```sh
xcodebuild test -project OnThisDay.xcodeproj -scheme OnThisDay \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

Unit tests cover date matching, screenshot exclusion, missing dates, grouping, ordering, leap days, and time zones. Real-device verification of iCloud downloads and limited-library permissions is recommended before distribution.
