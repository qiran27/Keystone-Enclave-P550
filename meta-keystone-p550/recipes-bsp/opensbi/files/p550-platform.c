#include "../../enclave.h"
#include "../../crypto.h"
#include "../../pmp.h"
#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/sbi_string.h>
#include <sbi/sbi_types.h>

#include "test_dev_key.h"

/*
 * Preserve the two inaccessible ranges installed by SiFive's EIC770x OpenSBI
 * patch. Keystone resets all PMP entries during sm_init(), so these ranges
 * must be represented in Keystone's own PMP allocator and restored per hart.
 */
#define P550_ACLINT_BASE    0x02000000UL
#define P550_ACLINT_SIZE    0x00010000UL
#define P550_LOW_HOLE_BASE  0x20000000UL
#define P550_LOW_HOLE_SIZE  0x20000000UL
#define P550_HIGH_HOLE_BASE 0x1000000000UL
#define P550_HIGH_HOLE_SIZE 0x7000000000UL

/*
 * The OpenSBI image has already executed by the time the P550 platform hook
 * runs, so its writable data and BSS no longer match fw_payload.bin.  Measure
 * the linker-defined RX area only.  The pinned OpenSBI 1.6 layout places
 * _fw_rw_start 0x40000 bytes after _fw_start; the payload builder verifies the
 * same range from the packaged reference image.
 */
extern char _fw_start[];
extern char _fw_rw_start[];

static region_id aclint_region = -1;
static region_id low_hole_region = -1;
static region_id high_hole_region = -1;

extern byte dev_public_key[PUBLIC_KEY_SIZE];

/*
 * The P550 release boot chain does not yet expose a hardware device root key
 * to OpenSBI.  Reproduce Keystone's test bootrom measurement and key setup so
 * the upstream attestation examples can exercise the complete report path.
 * These well-known keys provide no production identity or integrity claim.
 */
static void p550_init_test_attestation(void)
{
  byte sm_key_seed[MDSIZE];
  byte endorsement[MDSIZE + PUBLIC_KEY_SIZE];
  hash_ctx hash_ctx;
  size_t sm_measurement_size = (size_t)(_fw_rw_start - _fw_start);

  hash_init(&hash_ctx);
  hash_extend(&hash_ctx, _fw_start, sm_measurement_size);
  hash_finalize(sm_hash, &hash_ctx);

  hash_init(&hash_ctx);
  hash_extend(&hash_ctx, _sanctum_dev_secret_key,
              _sanctum_dev_secret_key_len);
  hash_extend(&hash_ctx, sm_hash, MDSIZE);
  hash_finalize(sm_key_seed, &hash_ctx);
  ed25519_create_keypair(sm_public_key, sm_private_key, sm_key_seed);

  sbi_memcpy(dev_public_key, _sanctum_dev_public_key, PUBLIC_KEY_SIZE);
  sbi_memcpy(endorsement, sm_hash, MDSIZE);
  sbi_memcpy(endorsement + MDSIZE, sm_public_key, PUBLIC_KEY_SIZE);
  sign(sm_signature, endorsement, sizeof(endorsement),
       _sanctum_dev_public_key, _sanctum_dev_secret_key);

  sbi_memset(sm_key_seed, 0, sizeof(sm_key_seed));
  sbi_memset(endorsement, 0, sizeof(endorsement));
}

unsigned long platform_init_global_once(void)
{
  p550_init_test_attestation();

  if (pmp_region_init_atomic(P550_LOW_HOLE_BASE, P550_LOW_HOLE_SIZE,
                             PMP_PRI_ANY, &low_hole_region, 1))
    return SBI_ERR_SM_ENCLAVE_PMP_FAILURE;

  if (pmp_region_init_atomic(P550_HIGH_HOLE_BASE, P550_HIGH_HOLE_SIZE,
                             PMP_PRI_ANY, &high_hole_region, 1))
    return SBI_ERR_SM_ENCLAVE_PMP_FAILURE;

  if (pmp_region_init_atomic(P550_ACLINT_BASE, P550_ACLINT_SIZE,
                             PMP_PRI_ANY, &aclint_region, 1))
    return SBI_ERR_SM_ENCLAVE_PMP_FAILURE;

  return SBI_ERR_SM_ENCLAVE_SUCCESS;
}
unsigned long platform_init_global(void)
{
  if (pmp_set_keystone(aclint_region, PMP_NO_PERM))
    return SBI_ERR_SM_ENCLAVE_PMP_FAILURE;
  if (pmp_set_keystone(low_hole_region, PMP_NO_PERM))
    return SBI_ERR_SM_ENCLAVE_PMP_FAILURE;
  if (pmp_set_keystone(high_hole_region, PMP_NO_PERM))
    return SBI_ERR_SM_ENCLAVE_PMP_FAILURE;

  /*
   * Entry 1 is the low NAPOT hole. Entry 3 is the upper bound/configuration
   * entry of the high TOR hole and locking it also locks pmpaddr2. These are
   * the only fixed deny entries that must affect M-mode speculation.
   */
  csr_set(CSR_PMPCFG0,
          ((unsigned long)PMP_L << (8 * 1)) |
          ((unsigned long)PMP_L << (8 * 3)));
  return SBI_ERR_SM_ENCLAVE_SUCCESS;
}

void platform_init_enclave(struct enclave *enclave) { (void)enclave; }
void platform_destroy_enclave(struct enclave *enclave) { (void)enclave; }

unsigned long platform_create_enclave(struct enclave *enclave)
{
  (void)enclave;
  return SBI_ERR_SM_ENCLAVE_SUCCESS;
}

void platform_switch_to_enclave(struct enclave *enclave) { (void)enclave; }
void platform_switch_from_enclave(struct enclave *enclave) { (void)enclave; }

uint64_t platform_random(void)
{
  static uint64_t w;
  static const uint64_t s = 0xb5ad4eceda1ce2a9ULL;
  unsigned long cycles;
  uint64_t x;

  /* Test-only fallback inherited from the VF2 port; not cryptographic RNG. */
  asm volatile ("rdcycle %0" : "=r" (cycles));
  x = cycles;
  x *= x;
  x += (w += s);
  return (x >> 32) | (x << 32);
}
