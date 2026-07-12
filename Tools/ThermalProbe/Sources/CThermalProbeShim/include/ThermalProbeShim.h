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

void tp_free_records(void *records);

#ifdef __cplusplus
}
#endif

#endif
