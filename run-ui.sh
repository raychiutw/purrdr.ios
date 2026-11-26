#!/bin/bash
# 用法: run-ui.sh <log 名> <plan> <only-testing 參數...>
cd /tmp/trim
name=$1; plan=$2; shift 2
lockf /tmp/purrdr-uitest.lock xcodebuild test-without-building -project src/App/Purrdr.xcodeproj -scheme Purrdr \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .derivedData \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing -skipPackagePluginValidation \
  -collect-test-diagnostics never -clonedSourcePackagesDirPath ~/Library/Caches/purrdr-spm \
  -testPlan $plan "$@" > /tmp/trim/$name.log 2>&1
echo EXIT $? >> /tmp/trim/$name.log
