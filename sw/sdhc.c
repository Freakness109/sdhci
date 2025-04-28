// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0/
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#define CROC_FLUSH_AFTER_PRINT

#include "uart.h"
#include "print.h"
#include "timer.h"
#include "gpio.h"
#include "util.h"

#include "sdmmcvar.h"
#include "sdhcvar.h"

int debug_funcs;
struct sdmmc_softc sc = { 0 };
struct sdhc_host hp = { 0 };

char text[] = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Donec sodales ac orci eget aliquet. Sed id libero pharetra, suscipit lorem nec, pellentesque felis. Duis finibus tellus quis commodo varius. Sed convallis dolor vel nisi ultricies scelerisque. Nulla semper, massa ac lacinia facilisis, tortor sem semper nunc, vitae vehicula eros ante id risus. Sed in ultricies orci. Cras ultricies neque ac lorem interdum, et cursus erat iaculis. Mauris dui purus, lacinia ut efficitur vitae, tempor vel sem. Nam feugiat ante magna. Mauris vel pretium lorem. Phasellus fermentum eros pharetra ex malesuada sodales. Praesent finibus, orci quis convallis mollis, sem libero sollicitudin eros, a auctor purus tellus ac erat. Suspendisse ullamcorper dui et tortor blandit, nec efficitur lorem eleifend. Fusce imperdiet ornare leo. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia curae; Quisque a tellus placerat, hendrerit dui id, volutpat orci. Suspendisse aliquam lacus at ultrices efficitur. Suspendisse fermentum pretium dui, non condimentum diam gravida eu. Aenean in risus nisl. Sed luctus diam non consequat fermentum. Aliquam ipsum justo, bibendum eu urna non, iaculis semper mauris. Duis a faucibus velit, vel tincidunt diam. Nunc at massa convallis, ornare nulla at, viverra sem. Vivamus lobortis lacinia ex, eget ornare sem laoreet quis. Nunc lorem ex, ornare in mauris vitae, mattis tempus est. Morbi sagittis dolor ac ante scelerisque imperdiet. Proin gravida non nisi quis malesuada. Phasellus condimentum eros at velit gravida vehicula. Nunc eget sollicitudin lorem. Maecenas eu neque et mauris imperdiet pulvinar id a augue. Nunc sit amet ligula eu magna laoreet faucibus. Etiam lobortis sapien dolor, vitae laoreet nulla ornare eu. Etiam consequat cursus sem non ullamcorper. Proin molestie pulvinar risus a dapibus. Sed a purus vestibulum elit aliquam bibendum a a neque. Nulla neque purus, dapibus sit amet orci mollis, commodo interdum nisl. Donec consectetur augue luctus, luctus velit et, tristique nisl vel.";
u_char data[2048] = { 0 };

void test_rw(int size) {

    // Reset Block
    int err = sdmmc_mem_write_block(&sc.sc_card, 0, data, size);
    if (err) printf("sdmmc_mem_write_block errored: %x\n", err);

    // To make sure the read actually reads
    bzero((void*) data, size);

    err = sdmmc_mem_read_block(&sc.sc_card, 0, data, size);
    if (err) printf("sdmmc_mem_read_block errored: %x\n", err);

    for (size_t i = 0; i < size; ++i) {
        if (data[i] != 0) {
            printf("data[%x] not as expected, should be 0, got %x\n", data[i]);
        }
    }

    if (err) printf("sdhc_bus_clock errored: %x\n", err);

    err = sdmmc_mem_write_block(&sc.sc_card, 0, (u_char*)text, size);
    if (err) printf("sdmmc_mem_write_block errored: %x\n", err);

    err = sdmmc_mem_read_block(&sc.sc_card, 0, data, size);
    if (err) printf("sdmmc_mem_read_block errored: %x\n", err);

    for (size_t i = 0; i < sizeof(data); ++i) {
        if (data[i] != text[i]) {
            printf("data[%x] not as expected, should be %x, got %x\n", text[i], data[i]);
        }
    }
}

extern int sdhcdebug;

int main() {
    uart_init(); // setup the uart peripheral

    // *reg16(SDHCI_BASE_ADDR, SDHCI_CLOCK_CONTROL_OFFSET) = 0x0004;

    // for (int i = 0; i < 8; i++) {
    //     printf("Setting Clock Div Reg to %x!\n", 1 << i);
    //     *reg8(SDHCI_BASE_ADDR, SDHCI_CLOCK_CONTROL_OFFSET + 1) = 1 << i;
    // }


    // printf("Read rsvd: %x\n", (unsigned) *reg8(SDHCI_BASE_ADDR, SDHCI_TRANSFER_MODE + 1));
    // *reg8(SDHCI_BASE_ADDR, SDHCI_TRANSFER_MODE + 1) = 0xFF;
    // printf("Read rsvd after write: %x\n", (unsigned) *reg8(SDHCI_BASE_ADDR, SDHCI_TRANSFER_MODE + 1));
    // uart_write_flush();

    // *reg16(SDHCI_BASE_ADDR, SDHCI_NORMAL_INTERRUPT_SIGNAL_ENABLE) = 0xFFFF;

    // // while (!(*reg16(SDHCI_BASE_ADDR, SDHCI_NORMAL_INTERRUPT_STATUS) & 0b100000)) printf(".\n");
    // asm volatile("csrs mie, %0" ::"r"(1 << 19) : "memory");
    // wfi();
    // printf("Interrupted!\n");

    // *reg16(SDHCI_BASE_ADDR, SDHCI_NORMAL_INTERRUPT_STATUS) = 0xFFFF;

    // uint32_t word;
    // for (int i = 0; i < 4; i++) {
    //     word = *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT);
    //     printf("'%x'\n", word);
    // }

    // uint32_t read[2] = { 0 };
    // *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT) = *(uint32_t*) "SDHC";
    // printf("Write Success!\n");
    // *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT) = *(uint32_t*) "m4w!";
    // printf("Write Success!\n");

    // read[0] = *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT);
    // printf("Read Success: '%s'\n", (char*) &read);
    // read[0] = *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT);
    // printf("Read Success: '%s'\n", (char*) &read);

    // *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT) = *(uint32_t*) "test";
    // printf("Write Success!\n");
    // read[0] = *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT);
    // printf("Read Success: '%s'\n", (char*) &read);

    // *reg32(SDHCI_BASE_ADDR, SDHCI_BUFFER_DATA_PORT) = *(uint32_t*) "SDHC";

    // *reg32(SDHCI_BASE_ADDR, 0x00C) = 0;

    // uint32_t state = *reg32(SDHCI_BASE_ADDR, SDHCI_PRESENT_STATE_OFFSET);
    // printf("Read Present State: '%x'\n", state);

    // *reg8(SDHCI_BASE_ADDR, SDHCI_COMMAND_OFFSET + 1) = 0;
    // printf("Wrote to Command Index\n");

    // // asm volatile("csrs mie, %0" ::"r"(1 << 19) : "memory");
    // // wfi();

    // state = *reg32(SDHCI_BASE_ADDR, SDHCI_PRESENT_STATE_OFFSET);
    // printf("Read Present State: '%x'\n", state);

    int size = 31;

    debug_funcs = 0;
    int err = sdhc_init(&hp, SDHCI_BASE_ADDR, 0, 0);
    if (err) printf("sdhc_init errored: %x\n", err);

// #define SDHC_INITIALIZED_MODEL
#ifdef SDHC_INITIALIZED_MODEL
    sc.sc_caps = SMC_CAPS_4BIT_MODE | SMC_CAPS_AUTO_STOP | SMC_CAPS_NONREMOVABLE;
    sc.sc_flags = SMF_SD_MODE | SMF_MEM_MODE | SMF_CARD_PRESENT | SMF_CARD_ATTACHED;
    sc.sch = &hp;

    sc.sc_card.sc = &sc;
    sc.sc_card.rca = 1;
    sc.sc_card.csd.capacity = 20000000;
    sc.sc_card.csd.sector_size = size;
#else
    sdmmc_init(&sc, &hp);
#endif

    // sdmmc_discover_cards(sc);


    err = sdhc_bus_clock(sc.sch, SDMMC_SDCLK_50MHZ,
        SDMMC_TIMING_LEGACY);
    if (err) printf("sdhc_bus_clock errored: %x\n", err);

    err = sdmmc_mem_set_blocklen(&sc, &sc.sc_card);
    if (err) printf("sdmmc_mem_set_blocklen errored: %x\n", err);

    debug_funcs = 1;

    err = sdmmc_mem_write_block(&sc.sc_card, 0, (void*)text, size);
    if (err) printf("sdmmc_mem_write_block errored: %x\n", err);

    err = sdmmc_mem_read_block(&sc.sc_card, 0, data, size);
    if (err) printf("sdmmc_mem_read_block errored: %x\n", err);

    for (int i = 0; i < size; i++) {
        printf("%x", data[i]);
        printf(i % 4 == 3 || i == size - 1 ? "\n" : " ");
    }


    // // Single block RW
    // test_rw(512);
    // // Multiple block RW
    // test_rw(2048);
    // // TODO half block rw?

    return 1;
}
