# For CocoaPods apps: pod "NotifySDK", :git => "https://github.com/hobbit254/notify-ios.git", :tag => "<version>"
# (it isn't on the CocoaPods registry). Swift Package Manager apps use Package.swift from the same repo.
Pod::Spec.new do |s|
  s.name          = "NotifySDK"
  s.version       = "0.1.0"
  s.summary       = "Notify in-app inbox for iOS: realtime connection, SQLite cache, NotificationCenterView."
  s.homepage      = "https://github.com/hobbit254/notify-ios"
  s.license       = { :type => "MIT", :file => "LICENSE" }
  s.authors       = "Kevin Mkenya"
  s.platforms     = { :ios => "16.0" }
  s.source        = { :git => "https://github.com/hobbit254/notify-ios.git", :tag => s.version.to_s }
  s.source_files  = "Sources/NotifySDK/**/*.swift"
  s.swift_version = "6.0"
  s.library       = "sqlite3"
end
