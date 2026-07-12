#include "ThermalProbeShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

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

static void tp_close_pipe(int descriptors[2]) {
    if (descriptors[0] >= 0) {
        close(descriptors[0]);
        descriptors[0] = -1;
    }
    if (descriptors[1] >= 0) {
        close(descriptors[1]);
        descriptors[1] = -1;
    }
}

static int tp_configure_pipe_reader(int descriptor) {
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
        return errno;
    }
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        return errno;
    }
    return 0;
}

static int tp_move_descriptor_above_stdio(int *descriptor) {
    if (*descriptor > STDERR_FILENO) {
        return 0;
    }
    int moved = fcntl(*descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (moved < 0) {
        return errno;
    }
    close(*descriptor);
    *descriptor = moved;
    return 0;
}

int32_t tp_spawn_process_group(
    const char *executable,
    char *const arguments[],
    TPSpawnedProcess *process,
    char *error,
    size_t error_capacity
) {
    if (executable == NULL || arguments == NULL || process == NULL) {
        tp_set_error(error, error_capacity, "invalid process spawn arguments");
        return EINVAL;
    }

    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        int status = errno;
        tp_close_pipe(stdout_pipe);
        tp_close_pipe(stderr_pipe);
        tp_set_error(error, error_capacity, strerror(status));
        return status;
    }
    int pipe_status = tp_move_descriptor_above_stdio(&stdout_pipe[0]);
    if (pipe_status == 0) {
        pipe_status = tp_move_descriptor_above_stdio(&stdout_pipe[1]);
    }
    if (pipe_status == 0) {
        pipe_status = tp_move_descriptor_above_stdio(&stderr_pipe[0]);
    }
    if (pipe_status == 0) {
        pipe_status = tp_move_descriptor_above_stdio(&stderr_pipe[1]);
    }
    if (pipe_status == 0) {
        pipe_status = tp_configure_pipe_reader(stdout_pipe[0]);
    }
    if (pipe_status == 0) {
        pipe_status = tp_configure_pipe_reader(stderr_pipe[0]);
    }
    if (pipe_status != 0) {
        tp_close_pipe(stdout_pipe);
        tp_close_pipe(stderr_pipe);
        tp_set_error(error, error_capacity, strerror(pipe_status));
        return pipe_status;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int status = posix_spawn_file_actions_init(&actions);
    int actions_initialized = status == 0;
    int attributes_initialized = 0;
    if (status == 0) {
        status = posix_spawnattr_init(&attributes);
        attributes_initialized = status == 0;
    }
    if (status == 0) {
        status = posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], STDERR_FILENO);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_addclose(&actions, stderr_pipe[1]);
    }
    sigset_t default_signals;
    if (status == 0) {
        if (sigemptyset(&default_signals) != 0
            || sigaddset(&default_signals, SIGINT) != 0
            || sigaddset(&default_signals, SIGTERM) != 0
            || sigaddset(&default_signals, SIGHUP) != 0) {
            status = errno;
        }
    }
    if (status == 0) {
        status = posix_spawnattr_setsigdefault(&attributes, &default_signals);
    }
    if (status == 0) {
        status = posix_spawnattr_setflags(
            &attributes,
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
        );
    }
    if (status == 0) {
        status = posix_spawnattr_setpgroup(&attributes, 0);
    }

    pid_t process_id = -1;
    if (status == 0) {
        status = posix_spawn(
            &process_id,
            executable,
            &actions,
            &attributes,
            arguments,
            environ
        );
    }

    if (actions_initialized) {
        posix_spawn_file_actions_destroy(&actions);
    }
    if (attributes_initialized) {
        posix_spawnattr_destroy(&attributes);
    }
    close(stdout_pipe[1]);
    stdout_pipe[1] = -1;
    close(stderr_pipe[1]);
    stderr_pipe[1] = -1;

    if (status != 0) {
        tp_close_pipe(stdout_pipe);
        tp_close_pipe(stderr_pipe);
        tp_set_error(error, error_capacity, strerror(status));
        return status;
    }

    process->process_id = process_id;
    process->stdout_fd = stdout_pipe[0];
    process->stderr_fd = stderr_pipe[0];
    return 0;
}

int32_t tp_wait_status_exit_code(int32_t status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

int32_t tp_process_has_exited(int32_t process_id, int32_t *has_exited) {
    if (process_id <= 0 || has_exited == NULL) {
        return EINVAL;
    }
    siginfo_t information;
    int status;
    do {
        memset(&information, 0, sizeof(information));
        status = waitid(
            P_PID,
            (id_t)process_id,
            &information,
            WEXITED | WNOHANG | WNOWAIT
        );
    } while (status != 0 && errno == EINTR);
    if (status != 0) {
        return errno;
    }
    *has_exited = information.si_pid == process_id ? 1 : 0;
    return 0;
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

typedef const void *TPIOReportSubscriptionRef;
typedef CFDictionaryRef (*TPIOReportCopyAllChannelsFn)(uint64_t, uint64_t);
typedef TPIOReportSubscriptionRef (*TPIOReportCreateSubscriptionFn)(
    CFTypeRef,
    CFMutableDictionaryRef,
    CFMutableDictionaryRef *,
    uint64_t,
    CFTypeRef
);
typedef CFDictionaryRef (*TPIOReportCreateSamplesFn)(
    TPIOReportSubscriptionRef,
    CFMutableDictionaryRef,
    CFTypeRef
);
typedef CFDictionaryRef (*TPIOReportCreateSamplesDeltaFn)(
    CFDictionaryRef,
    CFDictionaryRef,
    CFTypeRef
);
typedef CFStringRef (*TPIOReportChannelStringFn)(CFDictionaryRef);
typedef int64_t (*TPIOReportSimpleValueFn)(CFDictionaryRef, int32_t);
typedef int32_t (*TPIOReportStateCountFn)(CFDictionaryRef);
typedef CFStringRef (*TPIOReportStateNameFn)(CFDictionaryRef, int32_t);
typedef int64_t (*TPIOReportStateResidencyFn)(CFDictionaryRef, int32_t);

typedef struct {
    TPIOReportCopyAllChannelsFn copy_all_channels;
    TPIOReportCreateSubscriptionFn create_subscription;
    TPIOReportCreateSamplesFn create_samples;
    TPIOReportCreateSamplesDeltaFn create_samples_delta;
    TPIOReportChannelStringFn channel_group;
    TPIOReportChannelStringFn channel_subgroup;
    TPIOReportChannelStringFn channel_name;
    TPIOReportChannelStringFn channel_unit;
    TPIOReportSimpleValueFn simple_value;
    TPIOReportStateCountFn state_count;
    TPIOReportStateNameFn state_name;
    TPIOReportStateResidencyFn state_residency;
} TPIOReportAPI;

static int tp_ioreport_load_symbol(
    void *handle,
    const char *name,
    void **output,
    char *error,
    size_t error_capacity
) {
    dlerror();
    *output = dlsym(handle, name);
    const char *message = dlerror();
    if (*output == NULL || message != NULL) {
        char detail[256];
        snprintf(detail, sizeof(detail), "IOReport symbol %s is unavailable: %s",
                 name, message == NULL ? "not found" : message);
        tp_set_error(error, error_capacity, detail);
        return 0;
    }
    return 1;
}

static int tp_ioreport_load_api(
    void *handle,
    TPIOReportAPI *api,
    char *error,
    size_t error_capacity
) {
#define TP_LOAD_IOREPORT(field, name) \
    if (!tp_ioreport_load_symbol(handle, name, (void **)&api->field, error, error_capacity)) return 0
    TP_LOAD_IOREPORT(copy_all_channels, "IOReportCopyAllChannels");
    TP_LOAD_IOREPORT(create_subscription, "IOReportCreateSubscription");
    TP_LOAD_IOREPORT(create_samples, "IOReportCreateSamples");
    TP_LOAD_IOREPORT(create_samples_delta, "IOReportCreateSamplesDelta");
    TP_LOAD_IOREPORT(channel_group, "IOReportChannelGetGroup");
    TP_LOAD_IOREPORT(channel_subgroup, "IOReportChannelGetSubGroup");
    TP_LOAD_IOREPORT(channel_name, "IOReportChannelGetChannelName");
    TP_LOAD_IOREPORT(channel_unit, "IOReportChannelGetUnitLabel");
    TP_LOAD_IOREPORT(simple_value, "IOReportSimpleGetIntegerValue");
    TP_LOAD_IOREPORT(state_count, "IOReportStateGetCount");
    TP_LOAD_IOREPORT(state_name, "IOReportStateGetNameForIndex");
    TP_LOAD_IOREPORT(state_residency, "IOReportStateGetResidency");
#undef TP_LOAD_IOREPORT
    return 1;
}

static int tp_ioreport_append(
    TPIOReportRecord **records,
    size_t *count,
    size_t *capacity,
    const TPIOReportRecord *record
) {
    if (*count == *capacity) {
        size_t next_capacity = *capacity == 0 ? 256 : *capacity * 2;
        if (next_capacity > 1 << 20) {
            return 0;
        }
        TPIOReportRecord *next = realloc(*records, next_capacity * sizeof(**records));
        if (next == NULL) {
            return 0;
        }
        *records = next;
        *capacity = next_capacity;
    }
    (*records)[(*count)++] = *record;
    return 1;
}

static void tp_ioreport_copy_string(CFStringRef value, char *output, size_t capacity) {
    if (output == NULL || capacity == 0) {
        return;
    }
    output[0] = '\0';
    if (value != NULL) {
        CFStringGetCString(value, output, capacity, kCFStringEncodingUTF8);
    }
}

static void tp_ioreport_release(CFTypeRef value) {
    if (value != NULL) {
        CFRelease(value);
    }
}

int32_t tp_ioreport_copy_records(
    uint32_t sample_milliseconds,
    TPIOReportRecord **records,
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

    void *handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        tp_set_error(error, error_capacity, dlerror());
        return -2;
    }

    TPIOReportAPI api;
    memset(&api, 0, sizeof(api));
    if (!tp_ioreport_load_api(handle, &api, error, error_capacity)) {
        dlclose(handle);
        return -3;
    }

    CFDictionaryRef all_channels = api.copy_all_channels(0, 0);
    if (all_channels == NULL) {
        dlclose(handle);
        tp_set_error(error, error_capacity, "IOReportCopyAllChannels returned null");
        return -4;
    }
    CFMutableDictionaryRef channels = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault,
        0,
        all_channels
    );
    if (channels == NULL) {
        tp_ioreport_release(all_channels);
        dlclose(handle);
        tp_set_error(error, error_capacity, "IOReport channel dictionary could not be copied");
        return -5;
    }

    CFMutableDictionaryRef subscription_info = NULL;
    TPIOReportSubscriptionRef subscription = api.create_subscription(
        NULL,
        channels,
        &subscription_info,
        0,
        NULL
    );
    if (subscription_info != NULL) {
        CFRelease(subscription_info);
    }
    if (subscription == NULL) {
        tp_ioreport_release(channels);
        tp_ioreport_release(all_channels);
        dlclose(handle);
        tp_set_error(error, error_capacity, "IOReport subscription could not be created");
        return -6;
    }

    CFDictionaryRef first = api.create_samples(subscription, channels, NULL);
    uint32_t bounded_milliseconds = sample_milliseconds < 1
        ? 1
        : (sample_milliseconds > 5000 ? 5000 : sample_milliseconds);
    usleep((useconds_t)bounded_milliseconds * 1000);
    CFDictionaryRef second = api.create_samples(subscription, channels, NULL);
    CFDictionaryRef delta = first != NULL && second != NULL
        ? api.create_samples_delta(first, second, NULL)
        : NULL;
    tp_ioreport_release(first);
    tp_ioreport_release(second);

    if (delta == NULL) {
        tp_ioreport_release(subscription);
        tp_ioreport_release(channels);
        tp_ioreport_release(all_channels);
        dlclose(handle);
        tp_set_error(error, error_capacity, "IOReport delta sample could not be created");
        return -7;
    }

    CFArrayRef channel_array = (CFArrayRef)CFDictionaryGetValue(
        delta,
        CFSTR("IOReportChannels")
    );
    if (channel_array == NULL || CFGetTypeID(channel_array) != CFArrayGetTypeID()) {
        tp_ioreport_release(delta);
        tp_ioreport_release(subscription);
        tp_ioreport_release(channels);
        tp_ioreport_release(all_channels);
        dlclose(handle);
        tp_set_error(error, error_capacity, "IOReport delta has no channel array");
        return -8;
    }

    TPIOReportRecord *output = NULL;
    size_t written = 0;
    size_t capacity = 0;
    CFIndex channel_count = CFArrayGetCount(channel_array);
    int allocation_failed = 0;

    for (CFIndex index = 0; index < channel_count && !allocation_failed; ++index) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(channel_array, index);
        if (channel == NULL || CFGetTypeID(channel) != CFDictionaryGetTypeID()) {
            continue;
        }

        TPIOReportRecord base;
        memset(&base, 0, sizeof(base));
        tp_ioreport_copy_string(api.channel_group(channel), base.group, sizeof(base.group));
        tp_ioreport_copy_string(api.channel_subgroup(channel), base.subgroup, sizeof(base.subgroup));
        tp_ioreport_copy_string(api.channel_name(channel), base.channel, sizeof(base.channel));
        tp_ioreport_copy_string(api.channel_unit(channel), base.unit, sizeof(base.unit));
        base.state_index = -1;
        base.value = api.simple_value(channel, 0);
        if (!tp_ioreport_append(&output, &written, &capacity, &base)) {
            allocation_failed = 1;
            break;
        }

        int32_t state_count = api.state_count(channel);
        if (state_count < 0 || state_count > 4096) {
            continue;
        }
        for (int32_t state_index = 0; state_index < state_count; ++state_index) {
            TPIOReportRecord state = base;
            state.state_index = state_index;
            state.value = api.state_residency(channel, state_index);
            tp_ioreport_copy_string(
                api.state_name(channel, state_index),
                state.state,
                sizeof(state.state)
            );
            if (!tp_ioreport_append(&output, &written, &capacity, &state)) {
                allocation_failed = 1;
                break;
            }
        }
    }

    tp_ioreport_release(delta);
    tp_ioreport_release(subscription);
    tp_ioreport_release(channels);
    tp_ioreport_release(all_channels);
    dlclose(handle);

    if (allocation_failed) {
        free(output);
        tp_set_error(error, error_capacity, "IOReport record allocation failed");
        return -9;
    }
    if (written == 0) {
        free(output);
        tp_set_error(error, error_capacity, "IOReport returned no channel records");
        return -10;
    }

    TPIOReportRecord *trimmed = realloc(output, written * sizeof(*output));
    *records = trimmed == NULL ? output : trimmed;
    *count = written;
    return 0;
}

void tp_free_records(void *records) {
    free(records);
}
