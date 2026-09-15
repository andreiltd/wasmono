extern void __wasm_call_ctors(void);

int registered = 0;

void _start(void) {
    __wasm_call_ctors();
    if (registered != 42) {
        __builtin_trap();
    }
}
