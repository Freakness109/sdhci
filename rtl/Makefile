deps:
	@test `pwd` = '/fosic/designs/croc/rtl/user_domain/sdhci' && echo '[WARNING] THIS WILL NOT WORK INSIDE THE DOCKER IMAGE' || true

	mkdir -p model
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/rtl/verilog/sd_crc_7.v
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/rtl/verilog/sd_crc_16.v
	cd model && curl -O https://gist.githubusercontent.com/micha4w/38fad58c1cea3157f204709d4eca227e/raw/7e98a47f155b241f950cc3d75ccbd7db8f587e79/sdModel.v

clean:
	rm -rf model