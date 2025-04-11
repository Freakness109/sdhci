deps:
	@test `pwd` = '/fosic/designs/croc/rtl/user_domain/sdhci' && echo '[WARNING] THIS WILL NOT WORK INSIDE THE DOCKER IMAGE' || true

	mkdir -p model
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/rtl/verilog/sd_crc_7.v
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/rtl/verilog/sd_crc_16.v
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/bench/verilog/sdModel.v
	sed -i 's/ tri / inout tri /' model/sdModel.v

clean:
	rm -rf model