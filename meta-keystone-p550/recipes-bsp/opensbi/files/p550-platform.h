#ifndef KEYSTONE_P550_PLATFORM_H
#define KEYSTONE_P550_PLATFORM_H

struct platform_enclave_data {
};

/* Keep metadata deliberately small on an eight-entry PMP implementation. */
#define ENCL_MAX                3
#define ENCLAVE_REGIONS_MAX     4

/* Matches the vendor OpenSBI firmware interval and 2 MiB payload offset. */
#define SMM_BASE                0x80000000UL
#define SMM_SIZE                0x00200000UL

/* The SiFive P550 implements eight PMP address registers. */
#define PMP_N_REG               8
#define PMP_MAX_N_REGION        8

#define MAX_HARTS               4

void sm_copy_key(void);

#endif
