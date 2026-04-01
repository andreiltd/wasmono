_WASM_REFS = {
    "cpu": "config//cpu/constraints:cpu",
    "os": "config//os/constraints:os",
    "wasm32": "config//cpu/constraints:wasm32",
    "wasi": "config//os/constraints:wasi",
}

_WASIP1_REFS = dict(_WASM_REFS)
_WASIP1_REFS.update({
    "wasi_version": "wasmono//wasm/constraints:wasi_version",
    "wasip1": "wasmono//wasm/constraints:wasip1",
})

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

def _wasm_transition_p1_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    """Transition to WASM32-WASI with wasip1 constraint."""
    cpu_setting = refs.cpu[ConstraintSettingInfo]
    os_setting = refs.os[ConstraintSettingInfo]
    version_setting = refs.wasi_version[ConstraintSettingInfo]
    wasm32_value = refs.wasm32[ConstraintValueInfo]
    wasi_value = refs.wasi[ConstraintValueInfo]
    wasip1_value = refs.wasip1[ConstraintValueInfo]

    new_constraints = {}
    for setting_label, value in platform.configuration.constraints.items():
        if (setting_label != cpu_setting.label and
            setting_label != os_setting.label and
            setting_label != version_setting.label):
            new_constraints[setting_label] = value

    new_constraints[cpu_setting.label] = wasm32_value
    new_constraints[os_setting.label] = wasi_value
    new_constraints[version_setting.label] = wasip1_value

    new_cfg = ConfigurationInfo(
        constraints = new_constraints,
        values = platform.configuration.values,
    )

    return PlatformInfo(
        label = "wasm32-wasip1-transitioned",
        configuration = new_cfg,
    )

wasm_transition = transition(
    impl = _wasm_transition_impl,
    refs = _WASM_REFS,
)

wasm_transition_p1 = transition(
    impl = _wasm_transition_p1_impl,
    refs = _WASIP1_REFS,
)
