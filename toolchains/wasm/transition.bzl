_WASM_REFS = {
    "cpu": "config//cpu/constraints:cpu",
    "os": "config//os/constraints:os",
    "wasm32": "config//cpu/constraints:wasm32",
    "wasi": "config//os/constraints:wasi",
}

def _wasm_transition_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    """Transition function to force WASM32-WASI platform."""

    cpu_setting = refs.cpu[ConstraintSettingInfo]
    os_setting = refs.os[ConstraintSettingInfo]
    wasm32_value = refs.wasm32[ConstraintValueInfo]
    wasi_value = refs.wasi[ConstraintValueInfo]

    current_cpu = platform.configuration.constraints.get(cpu_setting.label)
    current_os = platform.configuration.constraints.get(os_setting.label)
    if current_cpu == wasm32_value and current_os == wasi_value:
        return platform

    new_constraints = {}
    for setting_label, value in platform.configuration.constraints.items():
        if (setting_label != cpu_setting.label and
            setting_label != os_setting.label):
            new_constraints[setting_label] = value

    new_constraints[cpu_setting.label] = wasm32_value
    new_constraints[os_setting.label] = wasi_value

    new_cfg = ConfigurationInfo(
        constraints = new_constraints,
        values = platform.configuration.values,
    )

    return PlatformInfo(
        label = "wasm32-wasi-transitioned",
        configuration = new_cfg,
    )

wasm_transition = transition(
    impl = _wasm_transition_impl,
    refs = _WASM_REFS,
)
