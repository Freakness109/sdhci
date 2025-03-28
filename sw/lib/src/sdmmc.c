/*	$OpenBSD: sdmmc.c,v 1.62 2024/08/18 15:03:01 deraadt Exp $	*/

/*
 * Copyright (c) 2006 Uwe Stuehler <uwe@openbsd.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

/*
 * Host controller independent SD/MMC bus driver based on information
 * from SanDisk SD Card Product Manual Revision 2.2 (SanDisk), SDIO
 * Simple Specification Version 1.0 (SDIO) and the Linux "mmc" driver.
 */

#include "sdmmcchip.h"
#include "sdmmcreg.h"
#include "sdmmcvar.h"

#include "timer.h"

int	sdmmc_enable(struct sdmmc_softc *);
void	sdmmc_disable(struct sdmmc_softc *);
int	sdmmc_scan(struct sdmmc_softc *);
int	sdmmc_init(struct sdmmc_softc *);
void sdmmc_discover_task(void *arg);
void sdmmc_card_attach(struct sdmmc_softc *sc);
void sdmmc_card_detach(struct sdmmc_softc *sc, int flags);


#ifdef SDMMC_DEBUG
int sdmmcdebug = 0;
extern int sdhcdebug;	/* XXX should have a sdmmc_chip_debug() function */
void sdmmc_dump_command(struct sdmmc_softc *, struct sdmmc_command *);
#define DPRINTF(n,s)	do { if ((n) <= sdmmcdebug) printf s; } while (0)
#else
#define DPRINTF(n,s)	do {} while (0)
#endif


void
sdmmc_attach(struct sdmmc_softc *sc, struct sdmmcbus_attach_args *saa)
{
	int error;

	if (ISSET(saa->caps, SMC_CAPS_8BIT_MODE))
		printf(": 8-bit");
	else if (ISSET(saa->caps, SMC_CAPS_4BIT_MODE))
		printf(": 4-bit");
	else
		printf(": 1-bit");
	if (ISSET(saa->caps, SMC_CAPS_SD_HIGHSPEED))
		printf(", sd high-speed");
	if (ISSET(saa->caps, SMC_CAPS_UHS_SDR50))
		printf(", sdr50");
	if (ISSET(saa->caps, SMC_CAPS_UHS_SDR104))
		printf(", sdr104");
	if (ISSET(saa->caps, SMC_CAPS_MMC_HIGHSPEED))
		printf(", mmc high-speed");
	if (ISSET(saa->caps, SMC_CAPS_MMC_DDR52))
		printf(", ddr52");
	if (ISSET(saa->caps, SMC_CAPS_MMC_HS200))
		printf(", hs200");
	if (ISSET(saa->caps, SMC_CAPS_DMA))
		printf(", dma");
	printf("\n");

	sc->sct = saa->sct;
	sc->sch = saa->sch;
	sc->sc_dmat = saa->dmat;
	sc->sc_dmap = saa->dmap;
	sc->sc_flags = saa->flags;
	sc->sc_caps = saa->caps;
	sc->sc_max_seg = saa->max_seg ? saa->max_seg : MAXPHYS;
	sc->sc_max_xfer = saa->max_xfer;
	memcpy(&sc->sc_cookies, &saa->cookies, sizeof(sc->sc_cookies));

	// if (ISSET(sc->sc_caps, SMC_CAPS_DMA) && sc->sc_dmap == NULL) {
		// error = bus_dmamap_create(sc->sc_dmat, MAXPHYS, SDMMC_MAXNSEGS,
		//     sc->sc_max_seg, saa->dma_boundary,
		//     BUS_DMA_NOWAIT|BUS_DMA_ALLOCNOW,
		//     &sc->sc_dmap);
		// if (error) {
		// 	printf("%s: can't create DMA map\n", DEVNAME(sc));
		// 	return;
		// }
	// }

	/*
	 * Create the event thread that will attach and detach cards
	 * and perform other lengthy operations.  Enter config_pending
	 * state until the discovery task has run for the first time.
	 */
	SET(sc->sc_flags, SMF_CONFIG_PENDING);
	sdmmc_discover_task(sc);
}

int
sdmmc_detach(struct device *self, int flags)
{
	struct sdmmc_softc *sc = (struct sdmmc_softc *)self;
	sdmmc_card_detach(sc, DETACH_FORCE);

	return 0;
}

void
sdmmc_discover_task(void *arg)
{
	struct sdmmc_softc *sc = arg;

	if (sdmmc_chip_card_detect(sc->sct, sc->sch)) {
		if (!ISSET(sc->sc_flags, SMF_CARD_PRESENT)) {
			SET(sc->sc_flags, SMF_CARD_PRESENT);
			sdmmc_card_attach(sc);
		}
	} else {
		if (ISSET(sc->sc_flags, SMF_CARD_PRESENT)) {
			CLR(sc->sc_flags, SMF_CARD_PRESENT);
			// rw_enter_write(&sc->sc_lock);
			sdmmc_card_detach(sc, DETACH_FORCE);
			// rw_exit(&sc->sc_lock);
		}
	}

	if (ISSET(sc->sc_flags, SMF_CONFIG_PENDING)) {
		CLR(sc->sc_flags, SMF_CONFIG_PENDING);
		// config_pending_decr();
	}
}

/*
 * Called from process context when a card is present.
 */
void
sdmmc_card_attach(struct sdmmc_softc *sc)
{
	DPRINTF(1,("%s: attach card\n", DEVNAME(sc)));

	// rw_enter_write(&sc->sc_lock);
	CLR(sc->sc_flags, SMF_CARD_ATTACHED);

	/*
	 * Power up the card (or card stack).
	 */
	if (sdmmc_enable(sc) != 0) {
		printf("%s: can't enable card\n", DEVNAME(sc));
		goto err;
	}

	/*
	 * Scan for I/O functions and memory cards on the bus,
	 * allocating a sdmmc_function structure for each.
	 */
	if (sdmmc_scan(sc) != 0) {
		printf("%s: no functions\n", DEVNAME(sc));
		goto err;
	}

	/*
	 * Initialize the I/O functions and memory cards.
	 */
	if (sdmmc_init(sc) != 0) {
		printf("%s: init failed\n", DEVNAME(sc));
		goto err;
	}

	SET(sc->sc_flags, SMF_CARD_ATTACHED);
	// rw_exit(&sc->sc_lock);
	return;
err:
	sdmmc_card_detach(sc, DETACH_FORCE);
	// rw_exit(&sc->sc_lock);
}

/*
 * Called from process context with DETACH_* flags from <sys/device.h>
 * when cards are gone.
 */
void
sdmmc_card_detach(struct sdmmc_softc *sc, int flags)
{
	struct sdmmc_function *sf, *sfnext;

	// rw_assert_wrlock(&sc->sc_lock);

	DPRINTF(1,("%s: detach card\n", DEVNAME(sc)));

	if (ISSET(sc->sc_flags, SMF_CARD_ATTACHED)) {
		CLR(sc->sc_flags, SMF_CARD_ATTACHED);
	}

	/* Power down. */
	sdmmc_disable(sc);

	/* Free all sdmmc_function structures. */
	sdmmc_function_free(sc->sc_card);
	sc->sc_card = NULL;
}

int
sdmmc_enable(struct sdmmc_softc *sc)
{
	u_int32_t host_ocr;
	int error;

	// rw_assert_wrlock(&sc->sc_lock);

	/*
	 * Calculate the equivalent of the card OCR from the host
	 * capabilities and select the maximum supported bus voltage.
	 */
	host_ocr = sdmmc_chip_host_ocr(sc->sct, sc->sch);
	error = sdmmc_chip_bus_power(sc->sct, sc->sch, host_ocr);
	if (error != 0) {
		printf("%s: can't supply bus power\n", DEVNAME(sc));
		goto err;
	}

	/*
	 * Select the minimum clock frequency.
	 */
	error = sdmmc_chip_bus_clock(sc->sct, sc->sch,
	    SDMMC_SDCLK_400KHZ, SDMMC_TIMING_LEGACY);
	if (error != 0) {
		printf("%s: can't supply clock\n", DEVNAME(sc));
		goto err;
	}

	/* XXX wait for card to power up */
	sdmmc_delay(250000);

	/* Initialize SD I/O card function(s). */
	// if ((error = sdmmc_io_enable(sc)) != 0)
	// 	goto err;

	/* Initialize SD/MMC memory card(s). */
	if (ISSET(sc->sc_flags, SMF_MEM_MODE) &&
	    (error = sdmmc_mem_enable(sc)) != 0)
		goto err;

 err:
	if (error != 0)
		sdmmc_disable(sc);

	return error;
}

void
sdmmc_disable(struct sdmmc_softc *sc)
{
	/* XXX complete commands if card is still present. */

	// rw_assert_wrlock(&sc->sc_lock);

	/* Make sure no card is still selected. */
	(void)sdmmc_select_card(sc, NULL);

	/* Turn off bus power and clock. */
	(void)sdmmc_chip_bus_clock(sc->sct, sc->sch,
	    SDMMC_SDCLK_OFF, SDMMC_TIMING_LEGACY);
	(void)sdmmc_chip_bus_power(sc->sct, sc->sch, 0);
}

/*
 * Set the lowest bus voltage supported by the card and the host.
 */
int
sdmmc_set_bus_power(struct sdmmc_softc *sc, u_int32_t host_ocr,
    u_int32_t card_ocr)
{
	u_int32_t bit;

	// rw_assert_wrlock(&sc->sc_lock);

	/* Mask off unsupported voltage levels and select the lowest. */
	DPRINTF(1,("%s: host_ocr=%x ", DEVNAME(sc), host_ocr));
	host_ocr &= card_ocr;
	for (bit = 4; bit < 23; bit++) {
		if (ISSET(host_ocr, 1<<bit)) {
			host_ocr &= 3<<bit;
			break;
		}
	}
	DPRINTF(1,("card_ocr=%x new_ocr=%x\n", card_ocr, host_ocr));

	if (host_ocr == 0 ||
	    sdmmc_chip_bus_power(sc->sct, sc->sch, host_ocr) != 0)
		return 1;
	return 0;
}

struct sdmmc_function*
sdmmc_function_alloc(struct sdmmc_softc *sc)
{
	struct sdmmc_function* sf = sc->sc_card;
	bzero(sf, sizeof(*sf));

	sf->sc = sc;
	sf->number = -1;
	sf->cis.manufacturer = SDMMC_VENDOR_INVALID;
	sf->cis.product = SDMMC_PRODUCT_INVALID;
	sf->cis.function = SDMMC_FUNCTION_INVALID;
	sf->cur_blklen = sdmmc_chip_host_maxblklen(sc->sct, sc->sch);
	return sf;
}

void
sdmmc_function_free(struct sdmmc_function *sf)
{ }

/*
 * Scan for I/O functions and memory cards on the bus, allocating a
 * sdmmc_function structure for each.
 */
int
sdmmc_scan(struct sdmmc_softc *sc)
{
	// rw_assert_wrlock(&sc->sc_lock);

	/* Scan for memory cards on the bus. */
	if (ISSET(sc->sc_flags, SMF_MEM_MODE))
		sdmmc_mem_scan(sc);

	return 0;
}

/*
 * Initialize all the distinguished functions of the card, be it I/O
 * or memory functions.
 */
int
sdmmc_init(struct sdmmc_softc *sc)
{
	struct sdmmc_function *sf;

	// rw_assert_wrlock(&sc->sc_lock);

	if (ISSET(sc->sc_flags, SMF_MEM_MODE) &&
		sdmmc_mem_init(sc, sc->sc_card) != 0)
		printf("%s: mem init failed\n", DEVNAME(sc));

	if (!ISSET(sc->sc_card->flags, SFF_ERROR))
		return 0;

	/* No, we should probably power down the card. */
	return 1;
}

void
sdmmc_delay(u_int usecs)
{
	// TODO sleep_ms from croc
	sleep_ms(usecs / 1000);
}

int
sdmmc_app_command(struct sdmmc_softc *sc, struct sdmmc_command *cmd)
{
	struct sdmmc_command acmd;
	int error;

	// rw_assert_wrlock(&sc->sc_lock);

	bzero(&acmd, sizeof acmd);
	acmd.c_opcode = MMC_APP_CMD;
	acmd.c_arg = 0;
	if (sc->sc_card != NULL) {
		acmd.c_arg = sc->sc_card->rca << 16;
	}
	acmd.c_flags = SCF_CMD_AC | SCF_RSP_R1;

	error = sdmmc_mmc_command(sc, &acmd);
	if (error != 0) {
		return error;
	}

	if (!ISSET(MMC_R1(acmd.c_resp), MMC_R1_APP_CMD)) {
		/* Card does not support application commands. */
		return ENODEV;
	}

	error = sdmmc_mmc_command(sc, cmd);
	return error;
}

/*
 * Execute MMC command and data transfers.  All interactions with the
 * host controller to complete the command happen in the context of
 * the current process.
 */
int
sdmmc_mmc_command(struct sdmmc_softc *sc, struct sdmmc_command *cmd)
{
	int error;

	// rw_assert_wrlock(&sc->sc_lock);

	sdmmc_chip_exec_command(sc->sct, sc->sch, cmd);

#ifdef SDMMC_DEBUG
	sdmmc_dump_command(sc, cmd);
#endif

	error = cmd->c_error;

	return error;
}

/*
 * Send the "GO IDLE STATE" command.
 */
void
sdmmc_go_idle_state(struct sdmmc_softc *sc)
{
	struct sdmmc_command cmd;

	// rw_assert_wrlock(&sc->sc_lock);

	bzero(&cmd, sizeof cmd);
	cmd.c_opcode = MMC_GO_IDLE_STATE;
	cmd.c_flags = SCF_CMD_BC | SCF_RSP_R0;

	(void)sdmmc_mmc_command(sc, &cmd);
}

/*
 * Send the "SEND_IF_COND" command, to check operating condition
 */
int
sdmmc_send_if_cond(struct sdmmc_softc *sc, uint32_t card_ocr)
{
	struct sdmmc_command cmd;
	uint8_t pat = 0x23;	/* any pattern will do here */
	uint8_t res;

	// rw_assert_wrlock(&sc->sc_lock);

	bzero(&cmd, sizeof cmd);

	cmd.c_opcode = SD_SEND_IF_COND;
	cmd.c_arg = ((card_ocr & SD_OCR_VOL_MASK) != 0) << 8 | pat;
	cmd.c_flags = SCF_CMD_BCR | SCF_RSP_R7;

	if (sdmmc_mmc_command(sc, &cmd) != 0)
		return 1;

	res = cmd.c_resp[0];
	if (res != pat)
		return 1;
	else
		return 0;
}

/*
 * Retrieve (SD) or set (MMC) the relative card address (RCA).
 */
int
sdmmc_set_relative_addr(struct sdmmc_softc *sc,
    struct sdmmc_function *sf)
{
	struct sdmmc_command cmd;

	// rw_assert_wrlock(&sc->sc_lock);

	bzero(&cmd, sizeof cmd);

	if (ISSET(sc->sc_flags, SMF_SD_MODE)) {
		cmd.c_opcode = SD_SEND_RELATIVE_ADDR;
		cmd.c_flags = SCF_CMD_BCR | SCF_RSP_R6;
	} else {
		cmd.c_opcode = MMC_SET_RELATIVE_ADDR;
		cmd.c_arg = MMC_ARG_RCA(sf->rca);
		cmd.c_flags = SCF_CMD_AC | SCF_RSP_R1;
	}

	if (sdmmc_mmc_command(sc, &cmd) != 0)
		return 1;

	if (ISSET(sc->sc_flags, SMF_SD_MODE))
		sf->rca = SD_R6_RCA(cmd.c_resp);
	return 0;
}

int
sdmmc_select_card(struct sdmmc_softc *sc, struct sdmmc_function *sf)
{
	struct sdmmc_command cmd;
	int error;

	// rw_assert_wrlock(&sc->sc_lock);

	if (sc->sc_card == sf || (sf && sc->sc_card &&
	    sc->sc_card->rca == sf->rca)) {
		sc->sc_card = sf;
		return 0;
	}

	bzero(&cmd, sizeof cmd);
	cmd.c_opcode = MMC_SELECT_CARD;
	cmd.c_arg = sf == NULL ? 0 : MMC_ARG_RCA(sf->rca);
	cmd.c_flags = SCF_CMD_AC | (sf == NULL ? SCF_RSP_R0 : SCF_RSP_R1);
	error = sdmmc_mmc_command(sc, &cmd);
	if (error == 0 || sf == NULL)
		sc->sc_card = sf;
	return error;
}

#ifdef SDMMC_DEBUG
void
sdmmc_dump_command(struct sdmmc_softc *sc, struct sdmmc_command *cmd)
{
	int i;

	rw_assert_wrlock(&sc->sc_lock);

	DPRINTF(1,("%s: cmd %u arg=%#x data=%p dlen=%d flags=%#x "
	    "proc=\"%s\" (error %d)\n", DEVNAME(sc), cmd->c_opcode,
	    cmd->c_arg, cmd->c_data, cmd->c_datalen, cmd->c_flags,
	    curproc ? curproc->p_p->ps_comm : "", cmd->c_error));

	if (cmd->c_error || sdmmcdebug < 1)
		return;

	printf("%s: resp=", DEVNAME(sc));
	if (ISSET(cmd->c_flags, SCF_RSP_136))
		for (i = 0; i < sizeof cmd->c_resp; i++)
			printf("%02x ", ((u_char *)cmd->c_resp)[i]);
	else if (ISSET(cmd->c_flags, SCF_RSP_PRESENT))
		for (i = 0; i < 4; i++)
			printf("%02x ", ((u_char *)cmd->c_resp)[i]);
	printf("\n");
}
#endif
