# sextant — local checks (dogfood: the tool checks itself).
.PHONY: build fixture test lint ci bench

build:
	swift build

# The C-family tests need the fixture built AND its compile flags captured: without them they
# skip themselves, and a green run would mean nothing was checked. Doing it here is what keeps
# the local run and CI honest about the same thing.
fixture: build
	swift build --package-path Tests/Fixtures/IndexFixture --enable-index-store
	$$(swift build --show-bin-path)/sextant index --project Tests/Fixtures/IndexFixture >/dev/null

test:
	swift test

# Hygiene self-check with its own rules (no print-call: prints are legitimate in a CLI).
lint: build
	$$(swift build --show-bin-path)/sextant lint --project . --rules sextant-rules.json

ci: build fixture test lint
	@echo "✅ sextant CI passed"

# Local benchmark against sextant itself (the index comes from the SPM store): latency, payload, RSS.
# Does not gate CI: absolute numbers are machine-dependent — this is for tracking regressions by hand.
bench: build
	@$$(swift build --show-bin-path)/sextant index --project . >/dev/null 2>&1 || true
	@$$(swift build --show-bin-path)/sextant bench --project . --symbols RepoMap,IndexStore,RuleEngine --iterations 20

# Installs the release binary into ~/.local/bin (add it to PATH).
install:
	swift build -c release
	@mkdir -p $$HOME/.local/bin
	@cp "$$(swift build -c release --show-bin-path)/sextant" "$$HOME/.local/bin/sextant"
	@echo "✅ installed: $$HOME/.local/bin/sextant (add ~/.local/bin to PATH)"
