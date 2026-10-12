#if os(macOS)
import AppKit
typealias PlatformView = NSView
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformView = UIView
typealias PlatformImage = UIImage
#endif

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif
