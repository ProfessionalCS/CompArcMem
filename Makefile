VERILATOR ?= verilator
SV_SRCS := MemorySystem/cacheDataTypes.sv MemorySystem/llcd.sv # MemorySystem/dtlb.sv MemorySystem/lsq.sv MemorySystem/L1_Cache.sv
OBJ_DIR := build/obj_dir

.PHONY: all compile clean

all: compile

compile:
	$(VERILATOR) --cc -Wall --Mdir $(OBJ_DIR) $(SV_SRCS)


clean:
	rm -rf build