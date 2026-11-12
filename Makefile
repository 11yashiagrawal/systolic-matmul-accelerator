.DEFAULT_GOAL := help

PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
VIEWER ?= gtkwave
N ?= 4
RANDOM_CASES ?= 100
SEED ?= 1
WAVE_MODULE ?= systolic_top
WAVE_FILE ?= build/tb_$(WAVE_MODULE).vcd

# Discover files at invocation time, so new modules need no Makefile edits.
RTL := $(sort $(shell find rtl -type f -name '*.v'))
HEADERS := $(sort $(shell find rtl tb -type f -name '*.vh'))
INCLUDE_DIRS := $(sort rtl/include tb/common $(dir $(RTL) $(HEADERS)))
INCLUDES := $(addprefix -I,$(INCLUDE_DIRS))
TESTBENCHES := $(sort $(wildcard tb/tb_*.v))
MODULES := $(patsubst tb/tb_%.v,%,$(TESTBENCHES))

.PHONY: help lint vectors test waves clean FORCE

help:
	@echo 'make lint           Lint all available RTL with Verilator -Wall'
	@echo 'make vectors        Generate fixed-seed golden vectors (when available)'
	@echo 'make sim-<module>   Compile and run tb/tb_<module>.v'
	@echo 'make test           Generate vectors and run all available testbenches'
	@echo 'make waves          Run systolic_top and open its VCD (VIEWER=surfer also works)'
	@echo 'make clean          Remove build outputs and the generated vector link'

# Lint each module as a top to avoid MULTITOP warnings while retaining -Wall.
lint:
	@if test -z "$(RTL)"; then \
		echo 'SKIP lint: no RTL .v files yet'; \
	else \
		mkdir -p build; \
		for source in $(RTL); do \
			module=$$(basename "$$source" .v); \
			echo "LINT $$module"; \
			if $(VERILATOR) --lint-only -Wall --default-language 1364-2005 \
				--top-module "$$module" --Mdir build/obj_dir $(INCLUDES) $(RTL) \
				> "build/lint_$$module.log" 2>&1; then \
				cat "build/lint_$$module.log"; \
			else cat "build/lint_$$module.log"; exit 1; fi; \
		done; \
		echo 'PASS lint'; \
	fi

vectors:
	@if test ! -f model/gen_vectors.py; then \
		echo 'SKIP vectors: model/gen_vectors.py has not landed (#14)'; \
	else \
		if test -e sim/vectors || test -L sim/vectors; then \
			if test "$$(readlink sim/vectors)" != '../build/vectors'; then \
				echo 'ERROR: move existing sim/vectors aside; make uses a link to build/vectors'; \
				exit 1; \
			fi; \
		else mkdir -p sim; ln -s ../build/vectors sim/vectors || exit 1; fi; \
		mkdir -p build/vectors; \
		$(PYTHON) model/gen_vectors.py --n $(N) --random $(RANDOM_CASES) \
			--seed $(SEED) --out build/vectors; \
	fi

test: vectors $(addprefix sim-,$(MODULES))
	@if test -z "$(MODULES)"; then echo 'SKIP test: no tb/tb_*.v files yet'; fi

# FORCE makes repeated invocations rerun simulations, even with cached binaries.
# A shared vectors prerequisite also orders generation under make -j.
sim-%: vectors FORCE
	@if test ! -f tb/tb_$*.v; then \
		echo 'SKIP sim-$*: tb/tb_$*.v has not landed'; \
	elif test -z "$(filter %/$*.v,$(RTL))"; then \
		echo 'SKIP sim-$*: RTL module $*.v has not landed'; \
	elif test '$*' = systolic_top && test ! -f model/gen_vectors.py; then \
		echo 'SKIP sim-$*: golden vector generator has not landed (#14)'; \
	else \
		mkdir -p build; \
		echo 'COMPILE tb_$*'; \
		if $(IVERILOG) -g2005 -Wall $(INCLUDES) -s tb_$* \
			-o build/tb_$*.vvp $(RTL) tb/tb_$*.v > build/compile_tb_$*.log 2>&1; then \
			cat build/compile_tb_$*.log; \
		else cat build/compile_tb_$*.log; exit 1; fi; \
		if $(VVP) build/tb_$*.vvp > build/tb_$*.log 2>&1; then \
			cat build/tb_$*.log; \
		else cat build/tb_$*.log; exit 1; fi; \
		if grep -Eq '^FAIL[[:space:]]' build/tb_$*.log || \
			! grep -Eq '^PASS tb_$* [0-9]+/[0-9]+[[:space:]]*$$' build/tb_$*.log; then \
			echo 'FAIL tb_$*: missing PASS summary or a FAIL was reported (docs/spec.md section 10)'; \
			exit 1; \
		fi; \
	fi

waves: sim-$(WAVE_MODULE)
	@if test ! -f tb/tb_$(WAVE_MODULE).v || \
		test -z "$(filter %/$(WAVE_MODULE).v,$(RTL))"; then \
		echo 'SKIP waves: $(WAVE_MODULE) or its testbench has not landed'; \
	elif test '$(WAVE_MODULE)' = systolic_top && test ! -f model/gen_vectors.py; then \
		echo 'SKIP waves: golden vector generator has not landed (#14)'; \
	elif test ! -f "$(WAVE_FILE)"; then \
		echo 'ERROR: no $(WAVE_FILE); the testbench must dump a VCD there (or set WAVE_FILE)'; \
		exit 1; \
	else $(VIEWER) "$(WAVE_FILE)"; fi

clean:
	rm -rf build
	@if test -L sim/vectors && test "$$(readlink sim/vectors)" = '../build/vectors'; then \
		rm sim/vectors; \
	fi

FORCE:
