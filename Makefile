VERILATOR ?= verilator
SV_SRCS := cache/cacheDataTypes.sv cache/llcd.sv
OBJ_DIR := build/obj_dir
TOP     := llcd

.PHONY: all compile clean

all: compile

compile:
	$(VERILATOR) --cc -Wall --Mdir $(OBJ_DIR) --top-module $(TOP) $(SV_SRCS)


clean:
	rm -rf build