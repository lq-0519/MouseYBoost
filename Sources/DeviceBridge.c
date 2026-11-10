#include "DeviceBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
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

int MYBClassifySender(uint64_t senderID) {
    if (senderID == 0) {
        return -1;
    }
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IORegistryEntryIDMatching(senderID));
    if (service == IO_OBJECT_NULL) {
        return -1;
    }
    CFTypeRef vendor = copyProperty(service, CFSTR("VendorID"));
    CFTypeRef builtIn = copyProperty(service, CFSTR("Built-In"));
    int result = -1;
    int32_t vendorID = 0;
    if (vendor != NULL && CFGetTypeID(vendor) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)vendor, kCFNumberSInt32Type, &vendorID)) {
        bool isBuiltIn = builtIn != NULL
            && CFGetTypeID(builtIn) == CFBooleanGetTypeID()
            && CFBooleanGetValue((CFBooleanRef)builtIn);
        result = vendorID == 0x046d && !isBuiltIn ? 1 : 0;
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
