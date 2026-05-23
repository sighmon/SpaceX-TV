# SpaceX TV

Native tvOS SwiftUI app for watching SpaceX live streams on Apple TV.

The app plays X/Periscope HLS streams with `AVPlayerViewController`. It can use a user-supplied X API Bearer Token to fetch recent SpaceX posts, then keeps the newest 10 statuses that expose bundled `.m3u8` playlist URLs and lets the viewer choose which broadcast to watch.

## Broadcasts

Broadcast discovery prefers X API v2:

1. `GET /2/users/by/username/spacex`
2. `GET /2/users/{id}/tweets`

If no Bearer Token is configured or the API request fails, it falls back to fetching `https://x.com/spacex`, extracting SpaceX status IDs, and probing those status pages for embedded `.m3u8` URLs. No static HLS fallback URLs are bundled.

## Build

Open `SpaceXTV.xcodeproj` in Xcode and run the `SpaceXTV` target on an Apple TV simulator or device.
