#include "ThermalProbeShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TP_SMC_KERNEL_INDEX 2
#define TP_SMC_READ_BYTES 5
#define TP_SMC_READ_INDEX 8
#define TP_SMC_READ_KEY_INFO 9

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} TPSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_limit;
    uint32_t gpu_limit;
    uint32_t memory_limit;
} TPSMCPowerLimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} TPSMCKeyInfo;

typedef struct {
    uint32_t key;
    TPSMCVersion version;
    TPSMCPowerLimit power_limit;
    TPSMCKeyInfo key_info;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} TPSMCKeyData;

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(
    IOHIDEventSystemClientRef client,
    CFDictionaryRef matching
);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(
    IOHIDServiceClientRef service,
    CFStringRef property
);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(
    IOHIDServiceClientRef service,
    int64_t event_type,
    int32_t options,
    int64_t timeout
);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

static void tp_set_error(char *error, size_t capacity, const char *message) {
    if (error == NULL || capacity == 0) {
        return;
    }
    snprintf(error, capacity, "%s", message == NULL ? "unknown error" : message);
}

static uint32_t tp_fourcc(const char key[4]) {
    return ((uint32_t)(uint8_t)key[0] << 24)
        | ((uint32_t)(uint8_t)key[1] << 16)
        | ((uint32_t)(uint8_t)key[2] << 8)
        | (uint32_t)(uint8_t)key[3];
}

static void tp_fourcc_string(uint32_t value, char output[5]) {
    output[0] = (char)((value >> 24) & 0xff);
    output[1] = (char)((value >> 16) & 0xff);
    output[2] = (char)((value >> 8) & 0xff);
    output[3] = (char)(value & 0xff);
    output[4] = '\0';
}

static kern_return_t tp_smc_call(
    io_connect_t connection,
    TPSMCKeyData *input,
    TPSMCKeyData *output
) {
    size_t output_size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        TP_SMC_KERNEL_INDEX,
        input,
        sizeof(*input),
        output,
        &output_size
    );
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output->result != 0) {
        return kIOReturnError;
    }
    return KERN_SUCCESS;
}

static kern_return_t tp_smc_read_key(
    io_connect_t connection,
    const char key[4],
    TPSMCKeyData *value
) {
    TPSMCKeyData input;
    TPSMCKeyData output;
    memset(&input, 0, sizeof(input));
    input.key = tp_fourcc(key);
    input.data8 = TP_SMC_READ_KEY_INFO;

    kern_return_t result = tp_smc_call(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }

    TPSMCKeyInfo info = output.key_info;
    memset(&input, 0, sizeof(input));
    input.key = tp_fourcc(key);
    input.key_info.data_size = info.data_size;
    input.data8 = TP_SMC_READ_BYTES;

    result = tp_smc_call(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }

    memset(value, 0, sizeof(*value));
    value->key_info = info;
    value->result = output.result;
    value->status = output.status;
    memcpy(value->bytes, output.bytes, sizeof(value->bytes));
    return KERN_SUCCESS;
}

static io_connect_t tp_smc_open(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (matching == NULL
        || IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_connect_t fallback = IO_OBJECT_NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name = {0};
        IORegistryEntryGetName(service, name);

        io_connect_t candidate = IO_OBJECT_NULL;
        kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &candidate);
        if (result == KERN_SUCCESS && candidate != IO_OBJECT_NULL) {
            if (strcmp(name, "AppleSMCKeysEndpoint") == 0) {
                if (fallback != IO_OBJECT_NULL) {
                    IOServiceClose(fallback);
                }
                IOObjectRelease(service);
                IOObjectRelease(iterator);
                return candidate;
            }
            if (fallback == IO_OBJECT_NULL) {
                fallback = candidate;
            } else {
                IOServiceClose(candidate);
            }
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return fallback;
}

static kern_return_t tp_smc_key_at_index(
    io_connect_t connection,
    uint32_t index,
    char key[5]
) {
    TPSMCKeyData input;
    TPSMCKeyData output;
    memset(&input, 0, sizeof(input));
    input.data8 = TP_SMC_READ_INDEX;
    input.data32 = index;

    kern_return_t result = tp_smc_call(connection, &input, &output);
    if (result == KERN_SUCCESS) {
        tp_fourcc_string(output.key, key);
    }
    return result;
}

int32_t tp_smc_copy_records(
    TPSMCRecord **records,
    size_t *count,
    char *error,
    size_t error_capacity
) {
    if (records == NULL || count == NULL) {
        tp_set_error(error, error_capacity, "records and count are required");
        return -1;
    }
    *records = NULL;
    *count = 0;

    io_connect_t connection = tp_smc_open();
    if (connection == IO_OBJECT_NULL) {
        tp_set_error(error, error_capacity, "AppleSMCKeysEndpoint could not be opened");
        return -2;
    }

    TPSMCKeyData key_count_value;
    if (tp_smc_read_key(connection, "#KEY", &key_count_value) != KERN_SUCCESS
        || key_count_value.key_info.data_size < 4) {
        IOServiceClose(connection);
        tp_set_error(error, error_capacity, "SMC #KEY could not be read");
        return -3;
    }

    uint32_t key_count = ((uint32_t)key_count_value.bytes[0] << 24)
        | ((uint32_t)key_count_value.bytes[1] << 16)
        | ((uint32_t)key_count_value.bytes[2] << 8)
        | (uint32_t)key_count_value.bytes[3];
    if (key_count == 0 || key_count > 65536) {
        IOServiceClose(connection);
        tp_set_error(error, error_capacity, "SMC returned an invalid key count");
        return -4;
    }

    TPSMCRecord *output = calloc(key_count, sizeof(*output));
    if (output == NULL) {
        IOServiceClose(connection);
        tp_set_error(error, error_capacity, "SMC record allocation failed");
        return -5;
    }

    size_t written = 0;
    for (uint32_t index = 0; index < key_count; ++index) {
        char key[5] = {0};
        if (tp_smc_key_at_index(connection, index, key) != KERN_SUCCESS) {
            continue;
        }

        TPSMCKeyData value;
        if (tp_smc_read_key(connection, key, &value) != KERN_SUCCESS) {
            continue;
        }

        TPSMCRecord *record = &output[written++];
        memcpy(record->key, key, 5);
        tp_fourcc_string(value.key_info.data_type, record->data_type);
        record->data_size = value.key_info.data_size > 32 ? 32 : value.key_info.data_size;
        memcpy(record->bytes, value.bytes, record->data_size);
        record->status = value.status;
    }

    IOServiceClose(connection);
    if (written == 0) {
        free(output);
        tp_set_error(error, error_capacity, "SMC exposed no readable keys");
        return -6;
    }

    TPSMCRecord *trimmed = realloc(output, written * sizeof(*output));
    *records = trimmed == NULL ? output : trimmed;
    *count = written;
    return 0;
}

static void tp_copy_cf_value(CFTypeRef value, char *output, size_t capacity) {
    if (output == NULL || capacity == 0) {
        return;
    }
    output[0] = '\0';
    if (value == NULL) {
        return;
    }

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, output, capacity, kCFStringEncodingUTF8);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int64_t number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number)) {
            snprintf(output, capacity, "%lld", (long long)number);
        }
    }
}

static void tp_hid_copy_property_string(
    IOHIDServiceClientRef service,
    CFStringRef key,
    char *output,
    size_t capacity
) {
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, key);
    tp_copy_cf_value(value, output, capacity);
    if (value != NULL) {
        CFRelease(value);
    }
}

static uint64_t tp_hid_copy_property_uint64(
    IOHIDServiceClientRef service,
    CFStringRef key
) {
    uint64_t number = 0;
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, key);
    if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number);
    }
    if (value != NULL) {
        CFRelease(value);
    }
    return number;
}

int32_t tp_hid_copy_temperature_records(
    TPHIDRecord **records,
    size_t *count,
    char *error,
    size_t error_capacity
) {
    if (records == NULL || count == NULL) {
        tp_set_error(error, error_capacity, "records and count are required");
        return -1;
    }
    *records = NULL;
    *count = 0;

    int32_t usage_page = 0xff00;
    int32_t usage = 5;
    CFNumberRef page_value = CFNumberCreate(NULL, kCFNumberSInt32Type, &usage_page);
    CFNumberRef usage_value = CFNumberCreate(NULL, kCFNumberSInt32Type, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {page_value, usage_value};
    CFDictionaryRef matching = CFDictionaryCreate(
        NULL,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(page_value);
    CFRelease(usage_value);

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL || matching == NULL) {
        if (client != NULL) CFRelease(client);
        if (matching != NULL) CFRelease(matching);
        tp_set_error(error, error_capacity, "IOHID event system client could not be created");
        return -2;
    }

    IOHIDEventSystemClientSetMatching(client, matching);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    CFRelease(matching);
    if (services == NULL) {
        CFRelease(client);
        tp_set_error(error, error_capacity, "IOHID returned no temperature service array");
        return -3;
    }

    CFIndex service_count = CFArrayGetCount(services);
    TPHIDRecord *output = service_count > 0 ? calloc((size_t)service_count, sizeof(*output)) : NULL;
    if (service_count > 0 && output == NULL) {
        CFRelease(services);
        CFRelease(client);
        tp_set_error(error, error_capacity, "IOHID record allocation failed");
        return -4;
    }

    size_t written = 0;
    for (CFIndex index = 0; index < service_count; ++index) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        if (service == NULL) {
            continue;
        }

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
        if (event == NULL) {
            continue;
        }
        double celsius = IOHIDEventGetFloatValue(event, 15 << 16);
        CFRelease(event);
        if (!isfinite(celsius)) {
            continue;
        }

        TPHIDRecord *record = &output[written++];
        record->index = (uint32_t)index;
        record->celsius = celsius;
        tp_hid_copy_property_string(service, CFSTR("Product"), record->product, sizeof(record->product));
        tp_hid_copy_property_string(service, CFSTR("LocationID"), record->location, sizeof(record->location));
        if (record->location[0] == '\0') {
            tp_hid_copy_property_string(service, CFSTR("SensorID"), record->location, sizeof(record->location));
        }
        record->registry_id = tp_hid_copy_property_uint64(service, CFSTR("RegistryID"));
        if (record->registry_id == 0) {
            record->registry_id = tp_hid_copy_property_uint64(service, CFSTR("IORegistryEntryID"));
        }
    }

    CFRelease(services);
    CFRelease(client);
    if (written == 0) {
        free(output);
        tp_set_error(error, error_capacity, "IOHID exposed no readable temperature events");
        return -5;
    }

    TPHIDRecord *trimmed = realloc(output, written * sizeof(*output));
    *records = trimmed == NULL ? output : trimmed;
    *count = written;
    return 0;
}

void tp_free_records(void *records) {
    free(records);
}
