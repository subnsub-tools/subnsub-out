// out Mic: a virtual microphone for a Mac that is spoken to from another Mac.
//
// Two devices on one clock and one ring of samples:
//   "out Mic"       visible, input only: what meeting apps pick as their microphone.
//   "out Mic Feed"  hidden, output only: where out plays the audio another Mac sends.
// What is played into the feed at a sample time comes out of the microphone at that sample time, so
// apps see a microphone and nothing in their list of speakers. 48 kHz, two channels, 32-bit float.
// Written from the AudioServerPlugIn interface in CoreAudio/AudioServerPlugIn.h. out installs it from
// Settings (MicrophoneLink.swift) into /Library/Audio/Plug-Ins/HAL.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#define kManufacturer       "SUB&SUB"
#define kSampleRate         48000.0
#define kChannels           2
#define kBytesPerFrame      (kChannels * sizeof(Float32))
#define kRingFrames         16384

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Mic           = 2,
    kObjectID_MicStream     = 3,
    kObjectID_Feed          = 4,
    kObjectID_FeedStream    = 5,
};

typedef struct {
    AudioObjectID device, stream;
    const char* name;
    CFStringRef uid;
    Boolean input, hidden;
} DeviceInfo;

static const DeviceInfo* Info(AudioObjectID inObjectID) {
    static DeviceInfo mic, feed;
    static Boolean made = false;
    if (!made) {
        mic = (DeviceInfo){ kObjectID_Mic, kObjectID_MicStream, "out Mic", CFSTR("OutMic_UID"), true, false };
        feed = (DeviceInfo){ kObjectID_Feed, kObjectID_FeedStream, "out Mic Feed", CFSTR("OutMicFeed_UID"), false, true };
        made = true;
    }
    if (inObjectID == kObjectID_Mic || inObjectID == kObjectID_MicStream) return &mic;
    if (inObjectID == kObjectID_Feed || inObjectID == kObjectID_FeedStream) return &feed;
    return NULL;
}

static Boolean IsDevice(AudioObjectID inObjectID) { return inObjectID == kObjectID_Mic || inObjectID == kObjectID_Feed; }
static Boolean IsStream(AudioObjectID inObjectID) { return inObjectID == kObjectID_MicStream || inObjectID == kObjectID_FeedStream; }

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRunning[2] = { 0, 0 };      // the microphone's clients, the feed's
static UInt64 gAnchorHostTime = 0;          // shared by both, so their sample times agree
static Float64 gHostTicksPerFrame = 0;
static Float32 gRing[kRingFrames * kChannels];
// The absolute sample time each frame of the ring holds, or -1: what the microphone reads is the
// frame written for that very time, never one left from a turn of the ring before. Written last by
// the feed and read first and last by the microphone, which run on their own IO threads.
static _Atomic(SInt64) gStamp[kRingFrames];
#define kClockDomain        0x6F75744D  // 'outM': both devices run on this one clock

static void ForgetRing(void) {
    for (UInt32 frame = 0; frame < kRingFrames; frame++) atomic_store_explicit(&gStamp[frame], -1, memory_order_relaxed);
}

// MARK: Interface

static HRESULT OutMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG OutMic_AddRef(void* inDriver);
static ULONG OutMic_Release(void* inDriver);
static OSStatus OutMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus OutMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus OutMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus OutMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus OutMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus OutMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus OutMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean OutMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus OutMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus OutMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus OutMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus OutMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus OutMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus OutMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus OutMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus OutMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus OutMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus OutMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus OutMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    OutMic_QueryInterface, OutMic_AddRef, OutMic_Release,
    OutMic_Initialize, OutMic_CreateDevice, OutMic_DestroyDevice,
    OutMic_AddDeviceClient, OutMic_RemoveDeviceClient,
    OutMic_PerformDeviceConfigurationChange, OutMic_AbortDeviceConfigurationChange,
    OutMic_HasProperty, OutMic_IsPropertySettable, OutMic_GetPropertyDataSize, OutMic_GetPropertyData, OutMic_SetPropertyData,
    OutMic_StartIO, OutMic_StopIO, OutMic_GetZeroTimeStamp,
    OutMic_WillDoIOOperation, OutMic_BeginIOOperation, OutMic_DoIOOperation, OutMic_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// The factory named in Info.plist.
void* OutMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* OutMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT OutMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (requested != NULL) {
        if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
            pthread_mutex_lock(&gStateMutex);
            gRefCount++;
            pthread_mutex_unlock(&gStateMutex);
            *outInterface = gDriverRef;
            result = S_OK;
        }
        CFRelease(requested);
    }
    return result;
}

static ULONG OutMic_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG OutMic_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus OutMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = ((Float64)timebase.denom / (Float64)timebase.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    gAnchorHostTime = mach_absolute_time();
    ForgetRing();
    return 0;
}

static OSStatus OutMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OutMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OutMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    return inDriver == gDriverRef && IsDevice(inDeviceObjectID) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus OutMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    return inDriver == gDriverRef && IsDevice(inDeviceObjectID) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus OutMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    return inDriver == gDriverRef && IsDevice(inDeviceObjectID) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus OutMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    return inDriver == gDriverRef && IsDevice(inDeviceObjectID) ? 0 : kAudioHardwareBadObjectError;
}

// MARK: Properties

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

// The device's one stream, where the scope asks for its direction (global asks for either).
static UInt32 StreamsForScope(const DeviceInfo* inInfo, AudioObjectPropertyScope inScope, AudioObjectID* outID) {
    Boolean wanted = inScope == kAudioObjectPropertyScopeGlobal
        || (inInfo->input && inScope == kAudioObjectPropertyScopeInput)
        || (!inInfo->input && inScope == kAudioObjectPropertyScopeOutput);
    if (wanted) { *outID = inInfo->stream; return 1; }
    return 0;
}

static Boolean OutMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    }
    if (IsDevice(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyStreams:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
            return inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput;
        // Channels only where the device has them: the microphone's input, the feed's output.
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout: {
            const DeviceInfo* info = Info(inObjectID);
            return info->input ? inAddress->mScope == kAudioObjectPropertyScopeInput : inAddress->mScope == kAudioObjectPropertyScopeOutput;
        }
        }
        return false;
    }
    if (IsStream(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus OutMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    if (inDriver != gDriverRef || inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!OutMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    // One rate, one format: nothing can be changed.
    *outIsSettable = false;
    return 0;
}

static OSStatus OutMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!OutMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    AudioObjectID stream;
    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle:
        *outDataSize = sizeof(CFStringRef); return 0;
    case kAudioPlugInPropertyDeviceList: *outDataSize = 2 * sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyOwnedObjects:
        if (inObjectID == kObjectID_PlugIn) *outDataSize = 2 * sizeof(AudioObjectID);
        else if (IsDevice(inObjectID)) *outDataSize = StreamsForScope(Info(inObjectID), inAddress->mScope, &stream) * sizeof(AudioObjectID);
        else *outDataSize = 0;
        return 0;
    case kAudioDevicePropertyStreams:
        *outDataSize = StreamsForScope(Info(inObjectID), inAddress->mScope, &stream) * sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyRelatedDevices: *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
    case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription)); return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *outDataSize = sizeof(AudioStreamRangedDescription); return 0;
    default:
        *outDataSize = sizeof(UInt32); return 0;
    }
}

#define PUT(type, value) do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *((type*)outData) = (value); *outDataSize = sizeof(type); return 0; } while (0)

static OSStatus OutMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!OutMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector selector = inAddress->mSelector;

    if (inObjectID == kObjectID_PlugIn) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: {
            AudioObjectID devices[2] = { kObjectID_Mic, kObjectID_Feed };
            UInt32 count = inDataSize / sizeof(AudioObjectID);
            if (count > 2) count = 2;
            memcpy(outData, devices, count * sizeof(AudioObjectID));
            *outDataSize = count * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID device = kAudioObjectUnknown;
            if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                CFStringRef uid = *((const CFStringRef*)inQualifierData);
                if (uid != NULL && CFStringCompare(uid, Info(kObjectID_Mic)->uid, 0) == kCFCompareEqualTo) device = kObjectID_Mic;
                if (uid != NULL && CFStringCompare(uid, Info(kObjectID_Feed)->uid, 0) == kCFCompareEqualTo) device = kObjectID_Feed;
            }
            PUT(AudioObjectID, device);
        }
        case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsDevice(inObjectID)) {
        const DeviceInfo* info = Info(inObjectID);
        AudioObjectID stream;
        switch (selector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: PUT(CFStringRef, CFStringCreateWithCString(NULL, info->name, kCFStringEncodingUTF8));
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID: PUT(CFStringRef, info->uid);
        case kAudioDevicePropertyModelUID: PUT(CFStringRef, CFSTR("OutMic_ModelUID"));
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: PUT(AudioObjectID, inObjectID);
        case kAudioDevicePropertyClockDomain: PUT(UInt32, kClockDomain);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gRunning[info->input ? 0 : 1] > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            PUT(UInt32, running);
        }
        // Only the microphone may be a default device; the feed is for out alone.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, info->input && inAddress->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
        case kAudioDevicePropertyLatency: PUT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyIsHidden: PUT(UInt32, info->hidden ? 1 : 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return 0; }
            AudioValueRange range = { kSampleRate, kSampleRate };
            PUT(AudioValueRange, range);
        }
        case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            UInt32 count = StreamsForScope(info, inAddress->mScope, &stream);
            if (count > inDataSize / sizeof(AudioObjectID)) count = 0;
            if (count) *((AudioObjectID*)outData) = stream;
            *outDataSize = count * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsStream(inObjectID)) {
        const DeviceInfo* info = Info(inObjectID);
        switch (selector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, info->device);
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return 0;
        case kAudioStreamPropertyIsActive: PUT(UInt32, 1);
        case kAudioStreamPropertyDirection: PUT(UInt32, info->input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: PUT(UInt32, info->input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency: PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            PUT(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return 0; }
            AudioStreamRangedDescription ranged;
            ranged.mFormat = StreamFormat();
            ranged.mSampleRateRange.mMinimum = kSampleRate;
            ranged.mSampleRateRange.mMaximum = kSampleRate;
            PUT(AudioStreamRangedDescription, ranged);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus OutMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    if (inDriver != gDriverRef || inAddress == NULL) return kAudioHardwareIllegalOperationError;
    if (!OutMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: IO

static OSStatus OutMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    // Nothing running on either: start from silence.
    if (gRunning[0] == 0 && gRunning[1] == 0) ForgetRing();
    gRunning[inDeviceObjectID == kObjectID_Mic ? 0 : 1]++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus OutMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt32* running = &gRunning[inDeviceObjectID == kObjectID_Mic ? 0 : 1];
    if (*running > 0) (*running)--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

// One clock for both devices: the host clock from one anchor, a ring of frames per period. Worked
// out from the time alone, so the microphone and the feed always agree on a sample time.
static OSStatus OutMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 now = mach_absolute_time();
    UInt64 periods = now > gAnchorHostTime ? (UInt64)((Float64)(now - gAnchorHostTime) / ticksPerRing) : 0;
    *outSampleTime = (Float64)(periods * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)periods * ticksPerRing);
    *outSeed = 1;
    return 0;
}

static OSStatus OutMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    Boolean willDo = (inDeviceObjectID == kObjectID_Mic && inOperationID == kAudioServerPlugInIOOperationReadInput)
        || (inDeviceObjectID == kObjectID_Feed && inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus OutMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return inDriver == gDriverRef && IsDevice(inDeviceObjectID) ? 0 : kAudioHardwareBadObjectError;
}

// The feed writes at its output time; the microphone reads at its input time, and only a frame
// stamped with that time: one never written, or overwritten while it was read, is silence.
static OSStatus OutMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID) || inIOCycleInfo == NULL || ioMainBuffer == NULL) return kAudioHardwareBadObjectError;
    Float32* buffer = (Float32*)ioMainBuffer;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_FeedStream) {
        SInt64 start = (SInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            SInt64 time = start + frame;
            UInt64 slot = (UInt64)time % kRingFrames;
            atomic_store_explicit(&gStamp[slot], -1, memory_order_release);
            for (UInt32 channel = 0; channel < kChannels; channel++) gRing[slot * kChannels + channel] = buffer[frame * kChannels + channel];
            atomic_store_explicit(&gStamp[slot], time, memory_order_release);
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_MicStream) {
        SInt64 start = (SInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            SInt64 time = start + frame;
            UInt64 slot = (UInt64)time % kRingFrames;
            Boolean good = atomic_load_explicit(&gStamp[slot], memory_order_acquire) == time;
            for (UInt32 channel = 0; channel < kChannels; channel++) buffer[frame * kChannels + channel] = good ? gRing[slot * kChannels + channel] : 0;
            atomic_thread_fence(memory_order_acquire);
            if (good && atomic_load_explicit(&gStamp[slot], memory_order_relaxed) != time) {
                for (UInt32 channel = 0; channel < kChannels; channel++) buffer[frame * kChannels + channel] = 0;
            }
        }
    }
    return 0;
}

static OSStatus OutMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return inDriver == gDriverRef && IsDevice(inDeviceObjectID) ? 0 : kAudioHardwareBadObjectError;
}
