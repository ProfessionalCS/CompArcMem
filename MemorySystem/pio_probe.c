#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>

#define H2F_BASE  0xC0000000
#define H2F_SPAN  0x1000

/* PIO offsets per Qsys: out_0 at 0x10, out_1 at 0x08, in_0 at 0x00 */
#define OFF_PIO_IN   0x00   /* 64-bit read (status from FPGA) */
#define OFF_PIO_OUT1 0x08   /* 64-bit write (adder_b) */
#define OFF_PIO_OUT0 0x10   /* 64-bit write (adder_a) */

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }

    volatile void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) { perror("mmap"); return 1; }

    volatile uint32_t *r32 = (volatile uint32_t *)base;
    volatile uint64_t *r64 = (volatile uint64_t *)base;

    printf("=== H2F PIO Deep Probe ===\n\n");

    /* Dump first 16 32-bit words */
    printf("32-bit dump of H2F bridge:\n");
    for (int off = 0; off < 16; off++) {
        printf("  [0x%02X] = 0x%08X\n", off * 4, r32[off]);
    }

    /* 64-bit dump of first 8 qwords */
    printf("\n64-bit dump:\n");
    for (int off = 0; off < 8; off++) {
        printf("  [0x%02X] = 0x%016llX\n", off * 8, (unsigned long long)r64[off]);
    }

    /* Write a known pattern to PIO_OUT0 (adder_a) offset 0x10 */
    printf("\nWriting 0xAAAA5555 to [0x10] (PIO_OUT0 low 32)...\n");
    r32[0x10 / 4] = 0xAAAA5555;
    __asm__ __volatile__("dsb sy" ::: "memory");

    /* Read back from offset 0x10 */
    printf("  Read [0x10] = 0x%08X\n", r32[0x10 / 4]);

    /* Write to PIO_OUT1 (adder_b) offset 0x08 */
    printf("\nWriting 0xDEAD to [0x08] (PIO_OUT1 low 32)...\n");
    r32[0x08 / 4] = 0x0000DEAD;
    __asm__ __volatile__("dsb sy" ::: "memory");
    printf("  Read [0x08] = 0x%08X\n", r32[0x08 / 4]);

    /* Sleep a bit, then re-read the status PIO */
    usleep(100000);
    printf("\nAfter 100ms:\n  PIO_IN [0x00] = 0x%016llX\n", (unsigned long long)r64[0]);
    printf("  PIO_IN low  [0x00] = 0x%08X\n", r32[0]);
    printf("  PIO_IN high [0x04] = 0x%08X\n", r32[1]);

    /* Try writing to the read PIO (should be ignored) */
    printf("\nWriting 0x12345678 to [0x00] (PIO_IN, should be read-only)...\n");
    r32[0] = 0x12345678;
    __asm__ __volatile__("dsb sy" ::: "memory");
    printf("  PIO_IN [0x00] rebuilt = 0x%08X\n", r32[0]);

    printf("\n=== Done ===\n");

    munmap((void *)base, H2F_SPAN);
    close(fd);
    return 0;
}
