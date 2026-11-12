#ifndef MOUSE_Y_BOOST_DEVICE_BRIDGE_H
#define MOUSE_Y_BOOST_DEVICE_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

/// Registry-backed device identity shared by C classification and Swift event
/// routing. Unknown and unsupported devices must always keep their original input.
typedef CF_ENUM(int32_t, MYBDeviceKind) {
    /// The physical sender or its identifying properties could not be resolved.
    MYBDeviceKindUnknown = -1,
    /// The sender is identified but is outside the supported device categories.
    MYBDeviceKindOther = 0,
    /// An external Logitech device eligible for the independent mouse switch.
    MYBDeviceKindLogitechMouse = 1,
    /// A touchpad identified by its acceleration type or explicit HID usage,
    /// eligible for the independent trackpad switch regardless of its vendor.
    MYBDeviceKindTrackpad = 2,
};

/// Resolves the optional HID event SPI once, before the event worker starts.
/// Returns false on unsupported systems; callers must leave input unchanged.
bool MYBDeviceBridgeAvailable(void);

/// Reads the registry sender ID from a physical Quartz event.
/// Releases the copied HID event internally; zero means unidentified input.
uint64_t MYBEventSenderID(CGEventRef event);

/// Classifies trackpads before applying the existing external Logitech filter.
/// Trackpad detection uses explicit HID properties rather than product names or
/// vendor IDs, because Apple's built-in trackpad may report VendorID zero.
/// Unresolved senders return unknown and must not receive any synthesized input.
MYBDeviceKind MYBClassifySender(uint64_t senderID);

#endif
