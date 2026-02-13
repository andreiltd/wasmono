use anyhow::{bail, Context, Result};
use wasmtime::component::{Component, Linker, Val};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{ResourceTable, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

struct State {
    ctx: WasiCtx,
    table: ResourceTable,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.ctx,
            table: &mut self.table,
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        bail!("Usage: {} <text-to-validate> [component-path]", args[0]);
    }
    let text = &args[1];
    let component_path = if args.len() > 2 {
        args[2].clone()
    } else {
        env!("COMPONENT_PATH").to_string()
    };

    let mut config = Config::new();
    config.wasm_component_model(true);

    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, &component_path)?;

    let mut linker = Linker::<State>::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;

    let wasi = WasiCtxBuilder::new()
        .inherit_stdio()
        .build();

    let mut store = Store::new(
        &engine,
        State {
            ctx: wasi,
            table: ResourceTable::new(),
        },
    );

    let instance = linker.instantiate(&mut store, &component)?;

    let iface_idx = instance
        .get_export_index(&mut store, None, "wasmono:validator/validate@0.1.0")
        .context("Could not find 'wasmono:validator/validate@0.1.0' export")?;

    let func_idx = instance
        .get_export_index(&mut store, Some(&iface_idx), "validate-text")
        .context("Could not find 'validate-text' in interface")?;

    let func = instance
        .get_func(&mut store, &func_idx)
        .context("Could not get 'validate-text' function")?;

    let mut results = vec![Val::String(String::new())];
    func.call(&mut store, &[Val::String(text.clone())], &mut results)?;

    match &results[0] {
        Val::String(s) => println!("{s}"),
        other => bail!("Unexpected return type: {other:?}"),
    }

    Ok(())
}
