HEREROCKS := .tests/data/nvim/lazy-rocks/hererocks
LUAROCKS := $(HEREROCKS)/bin/luarocks
LUACOV := $(HEREROCKS)/bin/luacov
LUACOV_CONSOLE := $(HEREROCKS)/bin/luacov-console

.PHONY: test test-coverage coverage-report coverage-clean

test:
	nvim -l tests/minit.lua --busted tests/ -o utfTerminal

test-coverage: deps-coverage coverage-clean
	nvim -l tests/minit_coverage.lua --busted tests/ -o utfTerminal
	@$(MAKE) coverage-report

coverage-report:
	@test -f $(LUACOV) || { echo "Run 'make test-coverage' first to install dependencies"; exit 1; }
	@# Strip absolute CWD prefix so luacov-console can match paths
	@sed 's|$(CURDIR)/||g' luacov.stats.out > luacov.stats.out.tmp && mv luacov.stats.out.tmp luacov.stats.out
	$(LUACOV)
	$(LUACOV_CONSOLE)
	$(LUACOV_CONSOLE) --summary
	@echo ""
	@echo "Detailed report: luacov.report.out"

coverage-clean:
	rm -f luacov.stats.out luacov.report.out luacov.report.out.index

deps-coverage:
	@test -f $(LUAROCKS) || { echo "Bootstrap test env first: nvim -l tests/minit.lua tests/ -o utfTerminal"; exit 1; }
	$(LUAROCKS) install luacov
	$(LUAROCKS) install luacov-console
