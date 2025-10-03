#!/usr/bin/env bash

# Buck2 provides resources through this environment variable
WASMTIME="$BUCK_DEFAULT_RUNTIME_RESOURCES/runner/wasmtime-bin"
COMPONENT="$BUCK_DEFAULT_RUNTIME_RESOURCES/components/validator/validator_with_regex"

exec "$WASMTIME" run -Scli --invoke "validate-text(\"$1\")" "$COMPONENT"
