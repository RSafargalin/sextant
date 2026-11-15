# sextant — local checks (dogfood: the tool checks itself).
.PHONY: build fixture test lint golden ci bench

build:
	swift build

# The C-family tests need the fixture built AND its compile flags captured: without them they
# skip themselves, and a green run would mean nothing was checked. Doing it here is what keeps
# the local run and CI honest about the same thing.
# `sextant index` runs the build itself, in a build tree of its own inside the fixture's `.build`,
# so the store and the flags cover every file whatever was built in the fixture before.
# Every run of the binary here uses a home of its own, `.build/fixture-home`, so the real
# `~/Library/Caches/sextant` is not touched; the test process starts from a copy of that home
# (Tests/TestHome), which is how the tests find the fixture's flags.
FIXTURE_HOME := $(CURDIR)/.build/fixture-home

# Flags are read from what a build prints, and an incremental build of an already built fixture
# prints none: while that home holds no flags yet, the fixture's index build tree is cleaned first.
fixture: build
	@test -d "$(FIXTURE_HOME)/Library/Caches/sextant/compile-db" || swift package clean \
		--package-path Tests/Fixtures/IndexFixture --scratch-path Tests/Fixtures/IndexFixture/.build/sextant-index
	CFFIXED_USER_HOME="$(FIXTURE_HOME)" $$(swift build --show-bin-path)/sextant index --project Tests/Fixtures/IndexFixture >/dev/null

test:
	swift test

# Hygiene self-check with its own rules (no print-call: prints are legitimate in a CLI).
lint: build
	CFFIXED_USER_HOME="$(FIXTURE_HOME)" $$(swift build --show-bin-path)/sextant lint --project . --rules sextant-rules.json

# Semantic regressions on the fixture: fixed assertions over the store `sextant index` built for
# it above (the same step CI runs). A second build into the fixture's `.build` would add a second
# store and leave the choice to a policy.
golden: fixture
	CFFIXED_USER_HOME="$(FIXTURE_HOME)" $$(swift build --show-bin-path)/sextant golden --project Tests/Fixtures/IndexFixture --spec Tests/Fixtures/IndexFixture/golden.json

ci: build fixture test lint golden
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
