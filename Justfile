set shell := ["bash", "-euo", "pipefail", "-c"]

test:
    swift test
    bash Tests/ci/publish_release_test.sh

lint:
    swiftlint lint --config .swiftlint.yml --quiet
    bash -n scripts/*.sh Tests/ci/*.sh

build-dmg:
    bash scripts/build_dmg.sh

run:
    swift run BatteryMonitorCLI
