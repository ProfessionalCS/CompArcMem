VERILATOR ?= verilator
LLCD_SRCS := MemorySystem/cacheDataTypes.sv MemorySystem/llcd.sv
LLCD_TB_SRC := MemorySystem/llcdTb.sv
OBJ_DIR := build/obj_dir
FLAGS := --cc --exe --build -Wall -sv --timing

.PHONY: all compile run clean

all: compile

compile:
	mkdir -p $(OBJ_DIR)
	$(VERILATOR) $(FLAGS) --top-module llcdTb -Mdir $(OBJ_DIR) +incdir+MemorySystem $(LLCD_SRCS) $(LLCD_TB_SRC)

run: compile
	$(OBJ_DIR)/VllcdTb

clean:
	rm -rf build