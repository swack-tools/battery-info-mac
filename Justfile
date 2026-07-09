set shell := ["bash", "-euo", "pipefail", "-c"]

test:
    swift test
    bash Tests/ci/build_dmg_icon_test.sh
    bash Tests/ci/release_workflow_icon_test.sh
    bash Tests/ci/release_workflow_security_test.sh
    bash Tests/ci/publish_release_test.sh

lint:
    swiftlint lint --config .swiftlint.yml --quiet
    bash -n scripts/*.sh Tests/ci/*.sh

build-dmg:
    bash scripts/build_dmg.sh

run:
    swift run BatteryMonitorCLI
