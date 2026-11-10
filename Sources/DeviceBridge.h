#ifndef MOUSE_Y_BOOST_DEVICE_BRIDGE_H
#define MOUSE_Y_BOOST_DEVICE_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

/// Resolves the optional HID event SPI once, before the event worker starts.
/// Returns false on unsupported systems; callers must leave input unchanged.
bool MYBDeviceBridgeAvailable(void);

/// Reads the registry sender ID from a physical Quartz event.
/// Releases the copied HID event internally; zero means unidentified input.
uint64_t MYBEventSenderID(CGEventRef event);

/// Classifies a registry sender using its vendor and built-in properties.
/// Returns 1 for an external Logitech device, 0 for other devices, and -1
/// when the registry service or vendor identity cannot be resolved.
int MYBClassifySender(uint64_t senderID);

#endif
