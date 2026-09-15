def _constraint_from_configuration_impl(ctx: AnalysisContext) -> list[Provider]:
    configuration = ctx.attrs.configuration[ConfigurationInfo]
    if len(configuration.constraints) != 1 or configuration.values:
        fail("{} must define exactly one constraint and no config values".format(ctx.attrs.configuration.label))

    # Preserve the consumer Prelude's constraint identity and modifier providers.
    return list(ctx.attrs.configuration.providers) + configuration.constraints.values()

constraint_from_configuration = rule(
    impl = _constraint_from_configuration_impl,
    attrs = {
        "configuration": attrs.dep(providers = [ConfigurationInfo]),
    },
    is_configuration_rule = True,
)
