/*	$OpenBSD: sdhcvar.h,v 1.17 2023/04/19 02:01:02 dlg Exp $	*/

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

#ifndef _SDHCVAR_H_
#define _SDHCVAR_H_

#include "types.h"

struct sdhc_host;

struct sdhc_softc {
	// struct device sc_dev;
	struct sdhc_host* sc_host;
	u_int sc_flags;
	u_int sc_clkbase;

	bus_dma_tag_t sc_dmat;
	bus_size_t sc_dma_boundary;

	int (*sc_card_detect)(struct sdhc_softc *);
	int (*sc_signal_voltage)(struct sdhc_softc *, int);
};

struct sdhc_host {
	struct sdhc_softc *sc;		/* host controller device */

	u_int mmio;

	u_int16_t version;		/* specification version */
	u_int clkbase;			/* base clock frequency in KHz */
	int maxblklen;			/* maximum block length */
	int flags;			/* flags for this host */
	u_int32_t ocr;			/* OCR value from capabilities */
	u_int8_t regs[14];		/* host controller state */
	u_int16_t intr_status;		/* soft interrupt status */
	u_int16_t intr_error_status;	/* soft error status */

	// bus_dmamap_t adma_map;
	// bus_dma_segment_t adma_segs[1];
	// caddr_t adma2;

	uint16_t block_size;
	uint16_t block_count;
	uint16_t transfer_mode;
};

struct sdmmc_softc;
int	sdhc_init(struct sdhc_host *, struct sdhc_softc *, struct sdmmc_softc *, u_int, int, uint64_t, uint64_t capset);
void	sdhc_shutdown(void *);

void	sdhc_needs_discover(struct sdhc_softc *);

/* flag values */
#define SDHC_F_NOPWR0		(1 << 0)
#define SDHC_F_NONREMOVABLE	(1 << 1)
#define SDHC_F_NO_HS_BIT	(1 << 3)

#endif
