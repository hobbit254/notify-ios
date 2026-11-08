# NotifySDK for iOS

The [Notify](https://notify.hobbit254.org) in-app inbox for iOS 16+: a realtime connection (WebSocket, with
long-poll fallback), an SQLite cache that works offline, optimistic read and archive, and a ready-made
SwiftUI `NotificationCenterView`.

## Install

**Swift Package Manager.** In Xcode: File → Add Package Dependencies…, enter
`https://github.com/hobbit254/notify-ios`, and choose "Up to Next Major Version" from `0.1.0`. Or in a
`Package.swift`:

```swift
.package(url: "https://github.com/hobbit254/notify-ios.git", from: "0.1.0"),
// and in your target:
.product(name: "NotifySDK", package: "notify-ios"),
```

**CocoaPods** (it isn't on the CocoaPods registry, so name the repository):

```ruby
pod 'NotifySDK', :git => 'https://github.com/hobbit254/notify-ios.git', :tag => '0.1.0'
```

## Use

Your server signs a short-lived token for each signed-in user with your Notify app's signing secret; the
SDK asks for one when it connects and again before it expires. The Notify dashboard's SDKs page shows how,
with your app's values filled in.

```swift
import NotifySDK

let notify = Notify(.init(apiURL: URL(string: "https://notify.hobbit254.org")!) {
    try await myBackend.notifyToken() // calls your token route
})
try await notify.start()

// SwiftUI, inside a NavigationStack:
NotificationCenterView(notify)
```

`Notify` is an `ObservableObject`: build your own UI from `items`, `unread` and `status`, and change state
with `markRead(_:)`, `archive(_:)` and `markAllRead()`. Call `stop()` on sign-out.

## Licence

MIT. This repository is published from the Notify monorepo (`sdks/ios`); report problems to the Notify
team.
