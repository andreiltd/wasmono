_WASM_REFS = {
    "cpu": "config//cpu/constraints:cpu",
    "os": "config//os/constraints:os",
    "wasm32": "config//cpu/constraints:wasm32",
    "wasi": "config//os/constraints:wasi",
}

_WASI_VERSION_REFS = dict(_WASM_REFS)
_WASI_VERSION_REFS.update({
    "wasi_version": "wasmono//wasm/constraints:wasi_version",
    "wasip1": "wasmono//wasm/constraints:wasip1",
    "wasip2": "wasmono//wasm/constraints:wasip2",
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

def _wasm_transition_with_version(platform: PlatformInfo, refs: struct, wasi_version: ConstraintValueInfo, label: str) -> PlatformInfo:
    cpu_setting = refs.cpu[ConstraintSettingInfo]
    os_setting = refs.os[ConstraintSettingInfo]
    version_setting = refs.wasi_version[ConstraintSettingInfo]
    wasm32_value = refs.wasm32[ConstraintValueInfo]
    wasi_value = refs.wasi[ConstraintValueInfo]

    new_constraints = {}
    for setting_label, value in platform.configuration.constraints.items():
        if (setting_label != cpu_setting.label and
            setting_label != os_setting.label and
            setting_label != version_setting.label):
            new_constraints[setting_label] = value

    new_constraints[cpu_setting.label] = wasm32_value
    new_constraints[os_setting.label] = wasi_value
    new_constraints[version_setting.label] = wasi_version

    new_cfg = ConfigurationInfo(
        constraints = new_constraints,
        values = platform.configuration.values,
    )

    return PlatformInfo(
        label = label,
        configuration = new_cfg,
    )

def _wasm_transition_p1_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    """Transition to WASM32-WASI with wasip1 constraint."""
    wasip1_value = refs.wasip1[ConstraintValueInfo]
    return _wasm_transition_with_version(platform, refs, wasip1_value, "wasm32-wasip1-transitioned")

def _wasm_transition_for_wasi_impl(platform: PlatformInfo, refs: struct, attrs: struct) -> PlatformInfo:
    """Transition to WASM32-WASI with the WASI version requested by the rule."""
    wasi = attrs.wasi
    if wasi == None:
        wasi = "wasip1" if attrs.adapter != None else "wasip2"

    if wasi == "wasip1":
        version_value = refs.wasip1[ConstraintValueInfo]
    elif wasi == "wasip2":
        version_value = refs.wasip2[ConstraintValueInfo]
    else:
        fail("unsupported WASI version: {}".format(wasi))

    return _wasm_transition_with_version(
        platform,
        refs,
        version_value,
        "wasm32-{}-transitioned".format(wasi),
    )

wasm_transition = transition(
    impl = _wasm_transition_impl,
    refs = _WASM_REFS,
)

wasm_transition_p1 = transition(
    impl = _wasm_transition_p1_impl,
    refs = _WASI_VERSION_REFS,
)

wasm_transition_for_wasi = transition(
    impl = _wasm_transition_for_wasi_impl,
    refs = _WASI_VERSION_REFS,
    attrs = ["wasi", "adapter"],
)
