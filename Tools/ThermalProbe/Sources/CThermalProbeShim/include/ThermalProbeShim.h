#ifndef THERMAL_PROBE_SHIM_H
#define THERMAL_PROBE_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char key[5];
    char data_type[5];
    uint32_t data_size;
    uint8_t bytes[32];
    int32_t status;
} TPSMCRecord;

typedef struct {
    uint32_t index;
    char product[192];
    char location[96];
    uint64_t registry_id;
    double celsius;
} TPHIDRecord;

typedef struct {
    char group[96];
    char subgroup[96];
    char channel[192];
    char unit[48];
    char state[96];
    int32_t state_index;
    int64_t value;
} TPIOReportRecord;

typedef struct {
    int32_t process_id;
    int32_t stdout_fd;
    int32_t stderr_fd;
} TPSpawnedProcess;

int32_t tp_smc_copy_records(
    TPSMCRecord **records,
    size_t *count,
    char *error,
    size_t error_capacity
);

int32_t tp_hid_copy_temperature_records(
    TPHIDRecord **records,
    size_t *count,
    char *error,
    size_t error_capacity
);

int32_t tp_ioreport_copy_records(
    uint32_t sample_milliseconds,
    TPIOReportRecord **records,
    size_t *count,
    char *error,
    size_t error_capacity
);

int32_t tp_spawn_process_group(
    const char *executable,
    char *const arguments[],
    TPSpawnedProcess *process,
    char *error,
    size_t error_capacity
);

int32_t tp_wait_status_exit_code(int32_t status);
int32_t tp_process_has_exited(int32_t process_id, int32_t *has_exited);

void tp_free_records(void *records);

#ifdef __cplusplus
}
#endif

#endif
