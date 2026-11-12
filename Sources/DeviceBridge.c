#include "DeviceBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDeviceKeys.h>
#include <IOKit/hid/IOHIDEventServiceKeys.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <dlfcn.h>
#include <pthread.h>

/// Optional private entry points are dynamically resolved, never hard linked.
typedef CFTypeRef (*CopyHIDEventFunction)(CGEventRef);
/// HID sender IDs are IORegistry entry IDs, not USB product IDs.
typedef uint64_t (*GetSenderIDFunction)(CFTypeRef);
/// Process-wide initialization token prevents concurrent symbol resolution.
static pthread_once_t bridgeOnce = PTHREAD_ONCE_INIT;
/// Cached SPI addresses remain valid because the system frameworks stay loaded.
static CopyHIDEventFunction copyHIDEvent;
static GetSenderIDFunction getSenderID;

/// Initializes the bridge without loading any third-party library or device driver.
static void initializeBridge(void) {
    copyHIDEvent = (CopyHIDEventFunction)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
    getSenderID = (GetSenderIDFunction)dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
}

bool MYBDeviceBridgeAvailable(void) {
    pthread_once(&bridgeOnce, initializeBridge);
    return copyHIDEvent != NULL && getSenderID != NULL;
}

uint64_t MYBEventSenderID(CGEventRef event) {
    if (event == NULL || !MYBDeviceBridgeAvailable()) {
        return 0;
    }
    CFTypeRef hidEvent = copyHIDEvent(event);
    if (hidEvent == NULL) {
        return 0;
    }
    uint64_t sender = getSenderID(hidEvent);
    CFRelease(hidEvent);
    return sender;
}

/// Searches the sender and its ancestors because USB receivers may publish
/// their vendor identity on a parent of the HID event service.
static CFTypeRef copyProperty(io_registry_entry_t entry, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(
        entry, kIOServicePlane, key, kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
}

/// Compares registry numbers without assuming their backing integer width.
/// Missing or nonnumeric properties are never treated as a matching HID usage.
static bool numberEquals(CFTypeRef property, int32_t expected) {
    int32_t value = 0;
    return property != NULL && CFGetTypeID(property) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)property, kCFNumberSInt32Type, &value)
        && value == expected;
}

/// Recognizes built-in and external trackpads using explicit system metadata.
/// The acceleration type covers the current Apple trackpad event service; an
/// explicit Digitizer/TouchPad usage covers devices exposing HID usages instead.
/// A shared keyboard/trackpad product name alone is deliberately insufficient.
static bool isTrackpad(io_service_t service) {
    CFTypeRef acceleration = copyProperty(service, CFSTR(kIOHIDPointerAccelerationTypeKey));
    bool matched = acceleration != NULL
        && CFGetTypeID(acceleration) == CFStringGetTypeID()
        && CFEqual(acceleration, CFSTR(kIOHIDTrackpadAccelerationType));
    if (acceleration != NULL) {
        CFRelease(acceleration);
    }
    if (matched) {
        return true;
    }
    CFTypeRef usages = copyProperty(service, CFSTR(kIOHIDDeviceUsagePairsKey));
    if (usages != NULL && CFGetTypeID(usages) == CFArrayGetTypeID()) {
        CFArrayRef pairs = (CFArrayRef)usages;
        for (CFIndex index = 0; index < CFArrayGetCount(pairs); index++) {
            CFTypeRef pair = CFArrayGetValueAtIndex(pairs, index);
            if (pair == NULL || CFGetTypeID(pair) != CFDictionaryGetTypeID()) {
                continue;
            }
            CFDictionaryRef usage = (CFDictionaryRef)pair;
            if (numberEquals(CFDictionaryGetValue(usage, CFSTR(kIOHIDDeviceUsagePageKey)),
                             kHIDPage_Digitizer)
                && numberEquals(CFDictionaryGetValue(usage, CFSTR(kIOHIDDeviceUsageKey)),
                                kHIDUsage_Dig_TouchPad)) {
                matched = true;
                break;
            }
        }
    }
    if (usages != NULL) {
        CFRelease(usages);
    }
    return matched;
}

MYBDeviceKind MYBClassifySender(uint64_t senderID) {
    if (senderID == 0) {
        return MYBDeviceKindUnknown;
    }
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IORegistryEntryIDMatching(senderID));
    if (service == IO_OBJECT_NULL) {
        return MYBDeviceKindUnknown;
    }
    if (isTrackpad(service)) {
        IOObjectRelease(service);
        return MYBDeviceKindTrackpad;
    }
    CFTypeRef vendor = copyProperty(service, CFSTR("VendorID"));
    CFTypeRef builtIn = copyProperty(service, CFSTR("Built-In"));
    MYBDeviceKind result = MYBDeviceKindUnknown;
    int32_t vendorID = 0;
    if (vendor != NULL && CFGetTypeID(vendor) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)vendor, kCFNumberSInt32Type, &vendorID)) {
        bool isBuiltIn = builtIn != NULL
            && CFGetTypeID(builtIn) == CFBooleanGetTypeID()
            && CFBooleanGetValue((CFBooleanRef)builtIn);
        result = vendorID == 0x046d && !isBuiltIn
            ? MYBDeviceKindLogitechMouse : MYBDeviceKindOther;
    }
    if (vendor != NULL) {
        CFRelease(vendor);
    }
    if (builtIn != NULL) {
        CFRelease(builtIn);
    }
    IOObjectRelease(service);
    return result;
}
