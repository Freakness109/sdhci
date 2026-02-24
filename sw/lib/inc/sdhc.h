#pragma once
#include <stdint.h>
#include <stdbool.h>

struct sdhc_cfg {
    void *peripheral_base;
    uint16_t rca;
    uint8_t base_clk_freq;
    uint8_t timeout_clk_freq;
    bool timeout_is_mhz;
    bool hcs;
    bool is_simulation;
    bool use_dma;
    // To use debug printing, set the pre-processor definition SDHC_DEBUG_PRINTS=1
    // and set the print function to printf (or related)
    int (*print)(const char* fmt, ...);
    // needed to wait for the card after raising frequency
    void (*usleep)(uint64_t ticks);
};

typedef enum {
    SDHC_SUCCESS = 0,
    SDHC_NO_CARD,
    SDHC_CMD_TIMEOUT,
    SDHC_CMD_ERROR,
    SDHC_DATA_TIMEOUT,
    SDHC_DATA_ERROR,
    SDHC_NOT_SUPPORTED,
    SDHC_WRONG_INTERRUPT
} sdhc_error_e;

typedef enum {
    SDHC_400KHZ,
    SDHC_25MHZ,
    SDHC_50MHZ
} sdhc_speed_e;

typedef enum {
    SDHC_WIDTH_1_BIT,
    SDHC_WIDTH_4_BIT
} sdhc_data_width_e;

sdhc_error_e sdhc_init_library(struct sdhc_cfg *cfg, void *peripheral_base, void (*usleep)(uint64_t), bool is_simulation);
bool sdhc_get_card_present(struct sdhc_cfg *cfg);
sdhc_error_e sdhc_init_card(struct sdhc_cfg *cfg, sdhc_speed_e max_speed);

sdhc_error_e sdhc_read(struct sdhc_cfg *cfg, uint32_t address, uint8_t *data, uint32_t size);
sdhc_error_e sdhc_write(struct sdhc_cfg *cfg, uint32_t address, uint8_t *data, uint32_t size);
