#include <sdhc.h>
#include "sdhc_internal.h"
#include <stddef.h>

static INLINE uint32_t read32(struct sdhc_cfg *cfg, uint32_t offset) {
    return *(volatile uint32_t*)(cfg->peripheral_base + offset);
}
static INLINE uint16_t read16(struct sdhc_cfg *cfg, uint32_t offset) {
    return *(volatile uint16_t*)(cfg->peripheral_base + offset);
}
static INLINE uint8_t read8(struct sdhc_cfg *cfg, uint32_t offset) {
    return *((volatile uint8_t*)cfg->peripheral_base + offset);
}
static INLINE void write32(struct sdhc_cfg *cfg, uint32_t offset, uint32_t value) {
    *(volatile uint32_t*)(cfg->peripheral_base + offset) = value;
}
static INLINE void write16(struct sdhc_cfg *cfg, uint32_t offset, uint16_t value) {
    *(volatile uint16_t*)(cfg->peripheral_base + offset) = value;
}
static INLINE void write8(struct sdhc_cfg *cfg, uint32_t offset, uint8_t value) {
    *((volatile uint8_t*)cfg->peripheral_base + offset) = value;
}

static int sdhc_print_dummy(const char* fmt, ...) {
    return 0;
}

sdhc_error_e sdhc_init_library(struct sdhc_cfg *cfg, void *peripheral_base, bool is_simulation) {
    if (cfg->print == NULL) {
	cfg->print = sdhc_print_dummy;
    }

    // make sure no bad state is left over between runs
    write8(cfg, SOFTWARE_RESET, 0x1);
    // start up the internal clock so that it is stable by the time we need it
    write16(cfg, CLOCK_CONTROL, 0x01);
    cfg->peripheral_base = peripheral_base;
    cfg->is_simulation = is_simulation;
    cfg->use_dma = false;
    return SDHC_SUCCESS;
}

bool sdhc_get_card_present(struct sdhc_cfg *cfg) {
    return !!(read32(cfg, PRESENT_STATE) & (1<<16));
}

static INLINE uint8_t sdhc_response_type_bits(sdhc_response_type_e response_type) {
    // 0: no response
    // 1: 136 bits
    // 2: 48 bits
    // 3: 48 bits, check busy
    switch (response_type) {
	case SDHC_NO_RESPONSE:
	    return 0;
	case SDHC_R1:
	case SDHC_R3:
	case SDHC_R6:
	case SDHC_R7:
	    return 2;
	case SDHC_R1b:
	    return 3;
	case SDHC_R2:
	    return 1;
    }
    return 0;
}

static sdhc_error_e sdhc_error_for_error_interrupt(struct sdhc_cfg *cfg, uint16_t error_interrupt_status) {
    if (error_interrupt_status & (1 << 8)) {
	// ACMD error
	uint16_t autocmd_error = read16(cfg, AUTO_CMD_ERROR_STATUS);
	if (autocmd_error & (1 << 1)) {
	    return SDHC_CMD_TIMEOUT;
	}
	return SDHC_CMD_ERROR;
    }

    if (error_interrupt_status & (3 << 5)) {
	return SDHC_DATA_ERROR;
    }

    if (error_interrupt_status & (1 << 4)) {
	return SDHC_DATA_TIMEOUT;
    }

    if (error_interrupt_status & (7 << 1)) {
	return SDHC_CMD_ERROR;
    }

    if (error_interrupt_status & 1) {
	// this has priority over a command complete,
	// both might get set during a transfer
	return SDHC_CMD_TIMEOUT;
    }
    // we didn't identify the error
    return SDHC_CMD_ERROR;
}

static sdhc_error_e sdhc_handle_interrupt(struct sdhc_cfg *cfg, uint16_t normal_interrupt_status) {
    // ack interrupts
    write16(cfg, NORMAL_INTERRUPT_STATUS, normal_interrupt_status);

    if (normal_interrupt_status & (1 << 15)) {
	// error interrupt
	uint16_t error_interrupt_status = read16(cfg, ERROR_INTERRUPT_STATUS);
	// ack interrupts
	sdhc_error_e rc = sdhc_error_for_error_interrupt(cfg, error_interrupt_status);
	write16(cfg, ERROR_INTERRUPT_STATUS, error_interrupt_status);
	return rc;
    }
    // card removal interrupt
    if (normal_interrupt_status & (1 << 7)) {
	return SDHC_NO_CARD;
    }
    return SDHC_SUCCESS;
}

static sdhc_error_e sdhc_wait_for_interrupts(struct sdhc_cfg *cfg, uint16_t *normal_interrupt_status) {
    *normal_interrupt_status = 0;
    do {
	// wait for response
	*normal_interrupt_status = read16(cfg, NORMAL_INTERRUPT_STATUS);
    } while (*normal_interrupt_status == 0);

    return sdhc_handle_interrupt(cfg, *normal_interrupt_status);
}

static INLINE void sdhc_fill_response(struct sdhc_cfg *cfg, sdhc_response_type_e response_type, sdhc_response_t *response) {
    uint32_t temp;
    switch (response_type) {
	case SDHC_R1:
	case SDHC_R1b:
	    response->R1.card_status = read32(cfg, RESPONSE);
	    break;
	case SDHC_R2:
	    response->R2.cid1 = read32(cfg, RESPONSE);
	    response->R2.cid2 = read32(cfg, RESPONSE + 0x4);
	    response->R2.cid3 = read32(cfg, RESPONSE + 0x8);
	    // only bits 0-119, discard top 8
	    response->R2.cid4 = read32(cfg, RESPONSE + 0xC) & 0x00FFFFFF;
	    break;
	case SDHC_R3:
	    response->R3.ocr = read32(cfg, RESPONSE);
	    break;
	case SDHC_R6:
	    temp = read32(cfg, RESPONSE);
	    response->R6.new_rca = (temp >> 16) & 0xFFFF;
	    response->R6.short_card_status = temp & 0xFFFF;
	    break;
	case SDHC_R7:
	    temp = read32(cfg, RESPONSE);
	    response->R7.voltage_accepted = (temp >> 8) & 0xFF;
	    response->R7.check_pattern = temp & 0xFF;
	    break;
	case SDHC_NO_RESPONSE:
	    break;
    }
}

static sdhc_error_e sdhc_wait_for_buf_read(struct sdhc_cfg *cfg) {
    sdhc_error_e rc = SDHC_SUCCESS;

    if (read32(cfg, PRESENT_STATE) & (1 << 11)) {
	return SDHC_SUCCESS;
    }

    uint16_t normal_interrupt_status = 0;

    if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
	return rc;
    }

    if ((normal_interrupt_status & ((1 << 5) | 1)) == 0) {
	SDHC_DBG("Wrong interrupt, expected 1 << 5, got %x\n", normal_interrupt_status);
	return SDHC_WRONG_INTERRUPT;
    }

    return sdhc_wait_for_buf_read(cfg);
}

static sdhc_error_e sdhc_wait_for_buf_write(struct sdhc_cfg *cfg) {
    sdhc_error_e rc = SDHC_SUCCESS;

    if (read32(cfg, PRESENT_STATE) & (1 << 10)) {
	return SDHC_SUCCESS;
    }

    uint16_t normal_interrupt_status = 0;

    if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
	return rc;
    }

    if ((normal_interrupt_status & ((1 << 4) | 1)) == 0) {
	SDHC_DBG("Wrong interrupt, expected 1 << 4, got %x\n", normal_interrupt_status);
	return SDHC_WRONG_INTERRUPT;
    }

    return sdhc_wait_for_buf_write(cfg);
}

// assumes that
// - size is a multiple of 512
// - size <= 0xFFFF * 512
static sdhc_error_e sdhc_issue_data_cmd(struct sdhc_cfg *cfg, uint8_t cmd, uint32_t arg,
	sdhc_response_type_e response_type, sdhc_response_t *response,
	sdhc_transfer_direction_e transfer_direction, uint8_t *buf, size_t size) {

    if (size & 0x1ff && size != 8) {
	return SDHC_NOT_SUPPORTED;
    }
    if (size > (0xFFFF * 512)) {
	return SDHC_NOT_SUPPORTED;
    }

    sdhc_error_e rc = SDHC_SUCCESS;

    // is multiblock and block count enable
    uint16_t is_multiblock = size > 512 ? (1 << 5) | (1 << 1) : 0;
    if (is_multiblock) {
	write16(cfg, BLOCK_COUNT_16, size / 512);
    }

    uint16_t is_read = transfer_direction == SDHC_READ ? (1 << 4) : 0;

    // enable autocmd12
    uint16_t autocmd_enable = size == 8 ? 0 : 0x1 << 2;

    write16(cfg, TRANSFER_MODE, is_multiblock | is_read | autocmd_enable);
    write32(cfg, ARGUMENT, arg);

    bool index_check = !(response_type == SDHC_R2 || response_type == SDHC_R3);
    bool crc_check = !(response_type == SDHC_R3);
    uint8_t response_type_bits = sdhc_response_type_bits(response_type);
    // command index, normal command, data present,
    write16(cfg, COMMAND, (cmd << 8) | (1 << 5) | (index_check << 4) | (crc_check << 3) | response_type_bits);

    if (transfer_direction == SDHC_READ) {
	if (size < 512) {
	    if ((rc = sdhc_wait_for_buf_read(cfg)) != SDHC_SUCCESS) {
		goto out;
	    }

	    // data arrived
	    // TODO: point iDMA at register
	    uint32_t data;
	    for (size_t i = 0; i < size / 4; ++i) {
		data = read32(cfg, BUFFER_DATA_PORT);
		buf[4*i]   = (data >> 0 ) & 0xFF;
		buf[4*i+1] = (data >> 8 ) & 0xFF;
		buf[4*i+2] = (data >> 16) & 0xFF;
		buf[4*i+3] = (data >> 24) & 0xFF;
	    }
	} else {
	    for (; size > 0; size -= 512) {
		if ((rc = sdhc_wait_for_buf_read(cfg)) != SDHC_SUCCESS) {
		    goto out;
		}

		// data arrived
		// TODO: point iDMA at register
		uint32_t data;
		for (size_t i = 0; i < 512 / 4; ++i) {
		    data = read32(cfg, BUFFER_DATA_PORT);
		    buf[4*i]   = (data >> 0 ) & 0xFF;
		    buf[4*i+1] = (data >> 8 ) & 0xFF;
		    buf[4*i+2] = (data >> 16) & 0xFF;
		    buf[4*i+3] = (data >> 24) & 0xFF;
		}
		buf += 512;
	    }
	}

	// clear any pending that we missed
	uint16_t normal_interrupt_status = read16(cfg, NORMAL_INTERRUPT_STATUS);
	rc = sdhc_handle_interrupt(cfg, normal_interrupt_status);
	SDHC_DBG("Exiting with rc %d and interrupts %d\n", rc, normal_interrupt_status);
    } else {
	for (; size > 0; size -= 512) {
	    if ((rc = sdhc_wait_for_buf_write(cfg)) != SDHC_SUCCESS) {
		goto out;
	    }

	    // data arrived
	    // TODO: point iDMA at register
	    for (size_t i = 0; i < 512 / 4; ++i) {
		write32(cfg, BUFFER_DATA_PORT,
			buf[4*i] |
			buf[4*i+1] << 8  |
			buf[4*i+2] << 16 |
			buf[4*i+3] << 24);
	    }
	    buf += 512;
	}

	uint16_t normal_interrupt_status = 0;
	if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
	    goto out;
	}
	// allow for:
	// - stale buffer write ready
	// - command complete
	uint16_t retries = 2;
	while ((normal_interrupt_status & 0x2) == 0) {
	    if (retries == 0) {
		SDHC_DBG("Wrong interrupt, expected 2, got %x\n", normal_interrupt_status);
		rc = SDHC_WRONG_INTERRUPT;
		goto out;
	    }
	    if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
		goto out;
	    }
	    --retries;
	}
	if (read32(cfg, PRESENT_STATE) & (1 << 2)) {
	    // DAT line active, we should have another transfer complete
	    if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
		goto out;
	    }
	    if ((normal_interrupt_status & 0x2) == 0) {
		SDHC_DBG("Wrong interrupt, expected 2, got %x\n", normal_interrupt_status);
		rc = SDHC_WRONG_INTERRUPT;
		goto out;
	    }
	} else {
	    // clear any transfer complete that we might have missed
	    normal_interrupt_status = read16(cfg, NORMAL_INTERRUPT_STATUS);
	    rc = sdhc_handle_interrupt(cfg, normal_interrupt_status);
	}
    }

out:
    if (rc == SDHC_SUCCESS) {
	sdhc_fill_response(cfg, response_type, response);
    } else {
	response->R2.cid1 = 0;
	response->R2.cid2 = 0;
	response->R2.cid3 = 0;
	response->R2.cid4 = 0;
    }
    return rc;
}

static sdhc_error_e sdhc_issue_cmd(struct sdhc_cfg *cfg, uint8_t cmd, uint32_t arg, sdhc_response_type_e response_type, sdhc_response_t *response) {
    sdhc_error_e rc = SDHC_SUCCESS;

    // single block, no autocmd, no block count
    write16(cfg, TRANSFER_MODE, 0x0);
    write32(cfg, ARGUMENT, arg);

    bool index_check = !(response_type == SDHC_R2 || response_type == SDHC_R3);
    bool crc_check = !(response_type == SDHC_R3);
    uint8_t response_type_bits = sdhc_response_type_bits(response_type);
    // command index, normal command, no data present, 
    write16(cfg, COMMAND, (cmd << 8) | (index_check << 4) | (crc_check << 3) | response_type_bits);

    uint16_t normal_interrupt_status = 0;
    if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
	return rc;
    }

    if (response_type != SDHC_R1b) {
	// we are waiting for a command complete
	if (normal_interrupt_status & 1) {
	    rc = SDHC_SUCCESS;
	} else {
	    // this should never happen
	    SDHC_DBG("Wrong interrupt, expected 1, got %x\n", normal_interrupt_status);
	    rc = SDHC_WRONG_INTERRUPT;
	}
    } else {
	bool seen_cmd_complete = !!(normal_interrupt_status & 1);
	bool seen_tx_complete = !!(normal_interrupt_status & 2);

	while (!(seen_cmd_complete) || !(seen_tx_complete)) {
	    if ((rc = sdhc_wait_for_interrupts(cfg, &normal_interrupt_status)) != SDHC_SUCCESS) {
		return rc;
	    }
	    seen_cmd_complete |= !!(normal_interrupt_status & 1);
	    seen_tx_complete |= !!(normal_interrupt_status & 2);
	}
	rc = SDHC_SUCCESS;
    }

    sdhc_fill_response(cfg, response_type, response);
    return rc;
}

static sdhc_error_e sdhc_issue_acmd(struct sdhc_cfg *cfg, uint8_t cmd, uint32_t arg, sdhc_response_type_e response_type, sdhc_response_t *response) {
    sdhc_error_e rc = SDHC_SUCCESS;
    if ((rc = sdhc_issue_cmd(cfg, 55, cfg->rca << 16, SDHC_R1, response)) != SDHC_SUCCESS) {
	return rc;
    }
    return sdhc_issue_cmd(cfg, cmd, arg, response_type, response);
}

static INLINE uint8_t sdhc_compute_clock_divider(struct sdhc_cfg *cfg, uint16_t freq_khz) {
    uint16_t base_freq_khz = cfg->base_clk_freq * 1000;
    if (freq_khz >= base_freq_khz)
	return 0;

    size_t shift = 0;
    for (; freq_khz < base_freq_khz; ++shift) {
	base_freq_khz >>= 1;
    }

    if (shift >= 8)
	return 1 << 7;
    return (1 << (shift - 1));
}

sdhc_error_e sdhc_init_card(struct sdhc_cfg *cfg, sdhc_speed_e max_speed) {
    sdhc_error_e rc;
    sdhc_response_t response;
    bool f8 = true;
    // TODO: implement speed selection
    (void)max_speed;

    if (!sdhc_get_card_present(cfg)) {
	return SDHC_NO_CARD;
    }

    // enable interrupt status
    // card removed, buffer r/w ready, tx/cmd complete
    write16(cfg, NORMAL_INTERRUPT_STATUS_ENABLE, 0xb3);
    // clear interrupts
    write16(cfg, NORMAL_INTERRUPT_STATUS, read16(cfg, NORMAL_INTERRUPT_STATUS));
    // autocmd, all data/cmd errors
    write16(cfg, ERROR_INTERRUPT_STATUS_ENABLE, 0x17f);
    // clear interrupts
    write16(cfg, ERROR_INTERRUPT_STATUS, read16(cfg, ERROR_INTERRUPT_STATUS));

    // set to the longest timeout possible
    write8(cfg, TIMEOUT_CONTROL, 0xe);

    uint16_t capabilities = read16(cfg, CAPABILITIES);
    cfg->base_clk_freq = (capabilities >> 8) & 0xFF;
    cfg->timeout_clk_freq = capabilities & 0x3F;
    cfg->timeout_is_mhz = !!(capabilities & 0x8);
    // 3.3V
    write8(cfg, POWER_CONTROL, 0xf);
    // enable clock and set to 400kHz for setup
    write16(cfg, CLOCK_CONTROL, 0x05 | (sdhc_compute_clock_divider(cfg, 400) << 8));

    // Reset card
    if ((rc = sdhc_issue_cmd(cfg, 0, 0, SDHC_NO_RESPONSE, &response)) != SDHC_SUCCESS) {
	return rc;
    }
    // check interface conditions
    // 0x1AB: 31-12: reserved, 11-8: supply voltage (2.7-3.6), 7:0 check pattern (any, here 0xAB)
    if ((rc = sdhc_issue_cmd(cfg, 8, 0x1AB, SDHC_R7, &response)) != SDHC_SUCCESS) {
	// this will time out on SD cards that implement v1.x
	// which is older than we want to support
	if (rc == SDHC_CMD_TIMEOUT)
	    f8 = false;
	else
	    return rc;
    }
    if (response.R7.check_pattern != 0xAB) {
	return SDHC_CMD_ERROR;
    }

    // Initialize card
    do {
	// 0x5030000: HCS+Maximum Performance, 3.2-3.4V supported
	if ((rc = sdhc_issue_acmd(cfg, 41, 0x10300000 | (f8 << 30), SDHC_R3, &response)) != SDHC_SUCCESS) {
	    return rc;
	}
    } while ((response.R3.ocr & (1 << 31)) == 0);
    cfg->hcs = !!(response.R3.ocr & (1 << 30));

    // Send card ID (legacy for multiple cards on bus)
    if ((rc = sdhc_issue_cmd(cfg, 2, 0, SDHC_R2, &response)) != SDHC_SUCCESS) {
	return rc;
    }

    // send RCA
    if ((rc = sdhc_issue_cmd(cfg, 3, 1, SDHC_R6, &response)) != SDHC_SUCCESS) {
	return rc;
    }
    cfg->rca = response.R6.new_rca;

    // set active card / switch to transfer mode
    if ((rc = sdhc_issue_cmd(cfg, 7, cfg->rca << 16, SDHC_R1b, &response)) != SDHC_SUCCESS) {
	return rc;
    }

    // set frequency to 25MHz
    write16(cfg, CLOCK_CONTROL, 0x05 | (sdhc_compute_clock_divider(cfg, 25000) << 8));

    // set block length to 512
    if ((rc = sdhc_issue_cmd(cfg, 16, 0x200, SDHC_R1, &response)) != SDHC_SUCCESS) {
	return rc;
    }
    write16(cfg, BLOCK_SIZE, 0x200);

    if (cfg->is_simulation) {
	// simulation model is broken and always uses 4-bit transfers, but still go through the motions
	write8(cfg, HOST_CONTROL_1, 0x2);
    }

    // acmd preamble
    if ((rc = sdhc_issue_cmd(cfg, 55, cfg->rca << 16, SDHC_R1, &response)) != SDHC_SUCCESS) {
	return rc;
    }
    // acmd51: read scr
    write16(cfg, BLOCK_SIZE, 0x8);
    uint8_t scr[8];
    if ((rc = sdhc_issue_data_cmd(cfg, 51, 0x0, SDHC_R1, &response, SDHC_READ, scr, sizeof(scr))) != SDHC_SUCCESS) {
	return rc;
    }

    uint8_t scr_bits_for_width = scr[1] & 0xF;

    // check scr for 4-bit-mode
    bool supported = !!(scr_bits_for_width & 0x4);
    if (supported) {
	// switch to 4-bit mode on the card
	if ((rc = sdhc_issue_acmd(cfg, 6, 0x2, SDHC_R1, &response)) != SDHC_SUCCESS) {
	    return rc;
	}
	// enable 4-bit mode on the controller
	write8(cfg, HOST_CONTROL_1, 0x2);
    }

    write16(cfg, BLOCK_SIZE, 0x200);

    return SDHC_SUCCESS;
}

sdhc_error_e sdhc_read(struct sdhc_cfg *cfg, uint32_t address, uint8_t *data, uint32_t size) {
    uint8_t buffer[512];
    sdhc_response_t response;
    sdhc_error_e rc = SDHC_SUCCESS;
    size_t max_read_size = 512 * 0xFFFF;

    if (address & 0x1FF) {
	if ((rc = sdhc_issue_data_cmd(cfg, 17, cfg->hcs ? address / 512 : address, SDHC_R1, &response, SDHC_READ, buffer, sizeof(buffer))) != SDHC_SUCCESS) {
	    return rc;
	}

	for (size_t i = address & 0x1FF; i < 512 && size > 0; ++i) {
	    *data = buffer[i];
	    ++data;
	    --size;
	}

	address &= ~0x1FF;
	address += 512;
    }

    while (size >= max_read_size) {
	if ((rc = sdhc_issue_cmd(cfg, 23, max_read_size / 512, SDHC_R1, &response)) != SDHC_SUCCESS) {
	    // timeout is fine, this is only a courtesy to the card
	    if (rc != SDHC_CMD_TIMEOUT) {
		return rc;
	    }
	}

	if ((rc = sdhc_issue_data_cmd(cfg, 18, cfg->hcs ? address / 512 : address, SDHC_R1, &response, SDHC_READ, data, max_read_size)) != SDHC_SUCCESS) {
	    return rc;
	}

	data += max_read_size;
	size -= max_read_size;
	address += max_read_size;
    }

    if (size > 512) {
	if ((rc = sdhc_issue_cmd(cfg, 23, size / 512, SDHC_R1, &response)) != SDHC_SUCCESS) {
	    // timeout is fine, this is only a courtesy to the card
	    if (rc != SDHC_CMD_TIMEOUT) {
		return rc;
	    }
	}
    }

    if (size > 0) {
	if ((rc = sdhc_issue_data_cmd(cfg, size > 512 ? 18 : 17, cfg->hcs ? address / 512 : address, SDHC_R1, &response, SDHC_READ, data, size)) != SDHC_SUCCESS) {
	    return rc;
	}
    }

    return SDHC_SUCCESS;
}

sdhc_error_e sdhc_write(struct sdhc_cfg *cfg, uint32_t address, uint8_t *data, uint32_t size) {

    sdhc_response_t response;
    sdhc_error_e rc = SDHC_SUCCESS;
    size_t max_write_size = 512 * 0xFFFF;

    if (address & 0x1FF) {
	// partial block writes will not go well
	return SDHC_NOT_SUPPORTED;
    }

    while (size >= max_write_size) {
	if ((rc = sdhc_issue_cmd(cfg, 23, max_write_size / 512, SDHC_R1, &response)) != SDHC_SUCCESS) {
	    // timeout is fine, this is only a courtesy to the card
	    if (rc != SDHC_CMD_TIMEOUT) {
		return rc;
	    }
	}

	if ((rc = sdhc_issue_data_cmd(cfg, 25, cfg->hcs ? address / 512 : address, SDHC_R1, &response, SDHC_WRITE, data, max_write_size)) != SDHC_SUCCESS) {
	    return rc;
	}

	data += max_write_size;
	size -= max_write_size;
	address += max_write_size;
    }

    if (size > 512) {
	if ((rc = sdhc_issue_cmd(cfg, 23, size / 512, SDHC_R1, &response)) != SDHC_SUCCESS) {
	    // timeout is fine, this is only a courtesy to the card
	    if (rc != SDHC_CMD_TIMEOUT) {
		return rc;
	    }
	}
    }

    if (size > 0) {
	if ((rc = sdhc_issue_data_cmd(cfg, size > 512 ? 25 : 24, cfg->hcs ? address / 512 : address, SDHC_R1, &response, SDHC_WRITE, data, size)) != SDHC_SUCCESS) {
	    return rc;
	}
    }

    return SDHC_SUCCESS;
}
