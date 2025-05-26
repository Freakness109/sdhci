// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0/
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

#include "uart.h"
#include "print.h"
#include "timer.h"
#include "gpio.h"
#include "util.h"

#include "sdmmcvar.h"
#include "sdhcvar.h"

struct sdmmc_softc sc = { 0 };
struct sdhc_host hp = { 0 };

static unsigned int s_Seed = 1;
unsigned int rand(void) {
    s_Seed = s_Seed * 1103515245 + 12345;
    return s_Seed;
}

#define SIZE     512
#define BLOCKS   5
static u_char scratch[SIZE * BLOCKS] = { 0 };
_Static_assert(sizeof(scratch) >= 512, "Scratch buffer needs to be atleast 512bytes");

void test_rw(int size, unsigned int seed) {
    printf("Running read write test with size %d\n", size);

    bzero((void*) scratch, size);

    // Reset Block
    int err;
    err = sdmmc_mem_write_block(&sc.sc_card, 0, scratch, size);
    if (err) {
        printf("sdmmc_mem_write_block errored: %x\n", err);
        return;
    }

    s_Seed = seed;
    for (size_t i = 0; i < size; ++i) scratch[i] = rand();

    err = sdmmc_mem_read_block(&sc.sc_card, 0, scratch, size);
    if (err) {
        printf("sdmmc_mem_read_block errored: %x\n", err);
        return;
    }

    for (size_t i = 0; i < size; ++i) {
        if (scratch[i] != 0) {
            printf("scratch[%d] not as expected, should be zeroed, got %x\n", i, scratch[i]);
            err = 1;
        }
    }
    if (err) return;


    s_Seed = seed;
    for (size_t i = 0; i < size; ++i) scratch[i] = rand();

    err = sdmmc_mem_write_block(&sc.sc_card, 0, scratch, size);
    if (err) {
        printf("sdmmc_mem_write_block errored: %x\n", err);
        return;
    }

    bzero((void*) scratch, size);

    err = sdmmc_mem_read_block(&sc.sc_card, 0, scratch, size);
    if (err) {
        printf("sdmmc_mem_read_block errored: %x\n", err);
        return;
    }

    s_Seed = seed;
    for (size_t i = 0; i < size; ++i) {
        char exp = rand();
        if (scratch[i] != exp) {
            printf("scratch[%d] not as expected, should be %x, got %x\n", i, exp, scratch[i]);
            err = 1;
        }
    }
    if (err) return;

    printf("Succesfuly ran read write test\n");
}

int main() {
    uart_init(); // setup the uart peripheral

#ifdef SDHC_DEBUG
    debug_funcs = 1;
    sdhcdebug = 2;
#endif

    int err = sdhc_init(&hp, SDHCI_BASE_ADDR, 0, 0);
    if (err) printf("sdhc_init errored: %x\n", err);

    // if (err) printf("1 errored: %x\n", err);
    // sleep_ms(1);
    // err = sdhc_bus_clock(&hp, SDMMC_SDCLK_OFF, SDMMC_TIMING_LEGACY);
    // if (err) printf("2 errored: %x\n", err);
    // sleep_ms(1);
    // if (err) printf("3 errored: %x\n", err);

    // sleep_ms(10);
    // return 1;

#ifdef WITH_SD_MODEL
    err = sdhc_bus_width(&hp, 4);
    if (err) printf("sdhc_bus_width errored: %x\n", err);
#endif

#ifdef SDHC_INITIALIZED_MODEL
    sc.sc_caps = SMC_CAPS_4BIT_MODE | SMC_CAPS_AUTO_STOP | SMC_CAPS_NONREMOVABLE;
    sc.sc_flags = SMF_SD_MODE | SMF_MEM_MODE | SMF_CARD_PRESENT | SMF_CARD_ATTACHED;
    sc.sch = &hp;

    sc.sc_card.sc = &sc;
    sc.sc_card.rca = 1;
    sc.sc_card.csd.capacity = 20000000;

    err = sdhc_bus_clock(sc.sch, SDMMC_SDCLK_400KHZ, SDMMC_TIMING_LEGACY);
    // err = sdhc_bus_clock(sc.sch, SDMMC_SDCLK_25MHZ, SDMMC_TIMING_LEGACY);
    if (err) printf("sdhc_bus_clock errored: %x\n", err);
#else
    sdmmc_init(&sc, &hp, scratch);
#endif

    sc.sc_card.csd.sector_size = SIZE;
    err = sdmmc_mem_set_blocklen(&sc, &sc.sc_card);
    if (err) printf("sdmmc_mem_set_blocklen errored: %x\n", err);


    // Single block RW
    test_rw(SIZE, 0xDEADBEEF);
    // Multiple block RW
    test_rw(BLOCKS*SIZE, 0x70EDADA1);
    // TODO half block rw?

    printf("\n");
    uart_write_flush();

    return 1;
}
