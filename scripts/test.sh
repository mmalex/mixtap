#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
  ${MIXTAP_TEST_FLAGS:-} Tests/AudioCoreTests.cpp -o build/tests/audio-core-tests
build/tests/audio-core-tests
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
  ${MIXTAP_TEST_FLAGS:-} Tests/WaveWriterTests.cpp \
  -framework AudioToolbox -framework CoreFoundation -o build/tests/wave-writer-tests
build/tests/wave-writer-tests
