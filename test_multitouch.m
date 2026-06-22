#import <Foundation/Foundation.h>
#include <dlfcn.h>

int main() {
    void* handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport", RTLD_NOW);
    if (!handle) {
        printf("Failed to load MultitouchSupport\n");
        return 1;
    }
    
    CFArrayRef (*MTDeviceCreateList)(void) = dlsym(handle, "MTDeviceCreateList");
    void* (*MTActuatorCreateFromDeviceID)(UInt64) = dlsym(handle, "MTActuatorCreateFromDeviceID");
    IOReturn (*MTActuatorOpen)(void*) = dlsym(handle, "MTActuatorOpen");
    IOReturn (*MTActuatorClose)(void*) = dlsym(handle, "MTActuatorClose");
    IOReturn (*MTActuatorActuate)(void*, SInt32, UInt32, Float32, Float32) = dlsym(handle, "MTActuatorActuate");
    UInt64 (*MTDeviceGetDeviceID)(void*) = dlsym(handle, "MTDeviceGetDeviceID");
    
    if (!MTDeviceCreateList || !MTActuatorOpen || !MTActuatorClose || !MTActuatorActuate || !MTDeviceGetDeviceID) {
        printf("Missing symbols\n");
        return 1;
    }
    
    CFArrayRef devices = MTDeviceCreateList();
    if (!devices || CFArrayGetCount(devices) == 0) {
        printf("No devices\n");
        return 1;
    }
    
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        void* device = (void*)CFArrayGetValueAtIndex(devices, i);
        UInt64 deviceID = MTDeviceGetDeviceID(device);
        printf("Device ID: 0x%llx\n", deviceID);
        
        void* actuator = MTActuatorCreateFromDeviceID(deviceID);
        if (actuator) {
            printf("Got actuator! Vibrating 3 times...\n");
            MTActuatorOpen(actuator);
            for (int j = 0; j < 3; j++) {
                MTActuatorActuate(actuator, 3, 0, 0, 0);
                usleep(200000); // 200ms
            }
            MTActuatorClose(actuator);
            printf("Success!\n");
            return 0;
        }
    }

    printf("Failed to get actuator\n");
    return 1;
}
