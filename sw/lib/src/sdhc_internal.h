#pragma once
#include <stdint.h>

#if FORCE_INLINE
#define INLINE __attribute__((always_inline)) inline
#define FLATTEN __attribute__((flatten))
#else
#define INLINE inline
#define FLATTEN
#endif

#if SDHC_DEBUG_PRINTS
#define SDHC_DBG(...) cfg->print(__VA_ARGS__)
#else
#define SDHC_DBG(...)
#endif

typedef enum {
    SDHC_NO_RESPONSE,
    SDHC_R1,
    SDHC_R1b,
    SDHC_R2,
    SDHC_R3,
    SDHC_R6,
    SDHC_R7
} sdhc_response_type_e;

typedef enum {
    SDHC_WRITE,
    SDHC_READ
} sdhc_transfer_direction_e;

typedef union {
    struct {
        uint32_t card_status;
    } R1;
    struct {
        uint32_t cid1;
        uint32_t cid2;
        uint32_t cid3;
        uint32_t cid4;
    } R2;
    struct {
        uint32_t ocr;
    } R3;
    struct {
        uint16_t new_rca;
        uint16_t short_card_status;
    } R6;
    struct {
        uint8_t voltage_accepted;
        uint8_t check_pattern;
    } R7;
} sdhc_response_t;

#define BLOCK_COUNT_32                        0x000
#define SDMA_SYS_ADDR                         BLOCK_COUNT_32
#define BLOCK_SIZE                            0x004
#define BLOCK_COUNT_16                        0x006
#define ARGUMENT                              0x008
#define TRANSFER_MODE                         0x00C
#define COMMAND                               0x00E
#define RESPONSE                              0x010
#define BUFFER_DATA_PORT                      0x020
#define PRESENT_STATE                         0x024
#define HOST_CONTROL_1                        0x028
#define POWER_CONTROL                         0x029
#define BLOCK_GAP_CONTROL                     0x02A
#define WAKEUP_CONTROL                        0x02B
#define CLOCK_CONTROL                         0x02C
#define TIMEOUT_CONTROL                       0x02E
#define SOFTWARE_RESET                        0x02F
#define NORMAL_INTERRUPT_STATUS               0x030
#define ERROR_INTERRUPT_STATUS                0x032
#define NORMAL_INTERRUPT_STATUS_ENABLE        0x034
#define ERROR_INTERRUPT_STATUS_ENABLE         0x036
#define NORMAL_INTERRUPT_SIGNAL_ENABLE        0x038
#define ERROR_INTERRUPT_SIGNAL_ENABLE         0x03A
#define AUTO_CMD_ERROR_STATUS                 0x03C
#define HOST_CONTROL_2                        0x03E
#define CAPABILITIES                          0x040
#define MAXIMUM_CURRENT_CAPABILITIES          0x048
#define FORCE_EVENT_AUTOCMD_ERROR_STATUS      0x050
#define FORCE_EVENT_ERROR_INTERRUPT_STATUS    0x052
#define ADMA_ERROR_STATUS                     0x054
#define ADMA_SYSTEM_ADDR_LOW                  0x058
#define ADMA_SYSTEM_ADDR_HIGH                 0x05C
#define PRESET_VALUE_INIT                     0x060
#define PRESET_VALUE_DEFAULT_SPEED            0x062
#define PRESET_VALUE_HIGH_SPEED               0x064
#define ADMA3_INTEGRATED_DESCRIPTOR_ADDR_LOW  0x078
#define ADMA3_INTEGRATED_DESCRIPTOR_ADDR_HIGH 0x07C
