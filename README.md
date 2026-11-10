# NotifySDK for iOS

The [Notify](https://notify.hobbit254.org) in-app inbox for iOS 16+: a realtime connection (WebSocket, with
long-poll fallback), an SQLite cache that works offline, optimistic read and archive, and a ready-made
SwiftUI `NotificationCenterView`.

## Install

**Swift Package Manager.** In Xcode: File → Add Package Dependencies…, enter
`https://github.com/hobbit254/notify-ios`, and choose "Up to Next Major Version" from `0.3.0`. Or in a
`Package.swift`:

```swift
.package(url: "https://github.com/hobbit254/notify-ios.git", from: "0.3.0"),
// and in your target:
.product(name: "NotifySDK", package: "notify-ios"),
```

**CocoaPods** (it isn't on the CocoaPods registry, so name the repository):

```ruby
pod 'NotifySDK', :git => 'https://github.com/hobbit254/notify-ios.git', :tag => '0.3.0'
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

## Mobile push

Optional. Notify can also deliver notifications as phone pushes through Firebase Cloud Messaging. This
package adds no Firebase code of its own: you set up Firebase Messaging in your app and pass Notify the
device's FCM registration token. Apps that only want the in-app inbox skip this section.

1. In the Notify dashboard, Settings → Apps → Set up mobile push…, upload your Firebase project's
   service-account key (Firebase → Project settings → Service accounts → Generate new private key). For
   iPhones, also upload your APNs key in Firebase → Project settings → Cloud Messaging.
2. In your app, after `start()`:

```swift
import FirebaseMessaging

// The FCM registration token, not the APNs device token. Also from
// messaging(_:didReceiveRegistrationToken:) whenever it changes.
if let token = Messaging.messaging().fcmToken { try await notify.registerPushToken(token) }

_ = try await notify.setPushEnabled(false) // the user's own switch; try await notify.preferences().push reads it
try await notify.unregisterPushToken(token) // on sign-out, before stop()
```

Pushes carry the notification's title and body, and `notification_id`, `inbox_item_id` and `url` (when it
has one) as data. Notify skips the push while the user has the app open, and for users who turned push
off. Send test push… in the dashboard checks the setup end to end.

## Licence

MIT. This repository is published from the Notify monorepo (`sdks/ios`); report problems to the Notify
team.
