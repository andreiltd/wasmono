use std::future::Future;

use anyhow::{Context, Result};
use bytes::Bytes;
use futures::SinkExt;
use http::HeaderValue;
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Collected};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{TrappableError, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_http::p3::bindings::http::types::ErrorCode;
use wasmtime_wasi_http::p3::{Request, RequestOptions, WasiHttpCtx, WasiHttpCtxView, WasiHttpView};
use wasmtime_wasi_http::types::DEFAULT_FORBIDDEN_HEADERS;

#[tokio::main]
async fn main() -> Result<()> {
    let component_path = std::env::args()
        .nth(1)
        .or_else(|| option_env!("COMPONENT_PATH").map(String::from))
        .context("usage: runner <component.wasm>")?;

    println!("Loading component: {component_path}");
    test_http_echo(&component_path).await
}

async fn test_http_echo(component_path: &str) -> Result<()> {
    let body = b"Hello from the HTTP P3 runner!";

    let (mut body_tx, body_rx) = futures::channel::mpsc::channel::<Result<_, ErrorCode>>(1);

    let request = http::Request::builder()
        .uri("http://localhost/")
        .method(http::Method::GET)
        .header("x-test", "hello")
        .body(http_body_util::StreamBody::new(body_rx))?;

    let send_body_task = async move {
        let _ = body_tx
            .send(Ok(http_body::Frame::data(Bytes::from_static(body))))
            .await;

        let _ = body_tx
            .send(Ok(http_body::Frame::trailers({
                let mut trailers = http::HeaderMap::new();
                trailers.insert("x-trailer", HeaderValue::from_static("test"));
                trailers
            })))
            .await;
        drop(body_tx);
    };

    let response_future = run_http(component_path, request);
    let (response, ()) = tokio::join!(response_future, send_body_task);
    let response = response?.unwrap();

    println!("Response status: {}", response.status().as_u16());
    for (name, value) in response.headers() {
        println!("  {name}: {}", value.to_str().unwrap_or("<binary>"));
    }

    let (_, collected_body) = response.into_parts();
    let body_bytes: Bytes = collected_body.to_bytes();
    println!(
        "Response body ({} bytes): {}",
        body_bytes.len(),
        String::from_utf8_lossy(&body_bytes)
    );

    Ok(())
}

async fn run_http<E: Into<ErrorCode> + 'static>(
    component_filename: &str,
    req: http::Request<impl http_body::Body<Data = Bytes, Error = E> + Send + Sync + 'static>,
) -> Result<Result<http::Response<Collected<Bytes>>, Option<ErrorCode>>> {
    let mut config = Config::new();
    config.async_support(true);
    config.wasm_component_model(true);
    config.wasm_component_model_async(true);

    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, component_filename)?;
    let mut store = Store::new(&engine, Ctx::default());

    let mut linker = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker)
        .context("failed to link wasi:cli@0.2.x")?;
    wasmtime_wasi::p3::add_to_linker(&mut linker)
        .context("failed to link wasi:cli@0.3.x")?;
    wasmtime_wasi_http::p3::add_to_linker(&mut linker)
        .context("failed to link wasi:http@0.3.x")?;

    let service = wasmtime_wasi_http::p3::bindings::Service::instantiate_async(
        &mut store, &component, &linker,
    )
    .await?;

    let (req, io) = Request::from_http(req);
    let (tx, rx) = tokio::sync::oneshot::channel();
    let ((handle_result, ()), res) = tokio::try_join!(
        async move {
            store
                .run_concurrent(async |store| {
                    tokio::try_join!(
                        async {
                            let (res, task) = match service.handle(store, req).await? {
                                Ok(pair) => pair,
                                Err(err) => return Ok(Err(Some(err))),
                            };
                            _ = tx.send(
                                store.with(|store| res.into_http(store, async { Ok(()) }))?,
                            );
                            task.block(store).await;
                            Ok(Ok(()))
                        },
                        async { io.await.context("failed to consume request body") }
                    )
                })
                .await?
        },
        async move {
            let res = rx.await?;
            let (parts, body) = res.into_parts();
            let body = body.collect().await.context("failed to collect body")?;
            Ok(http::Response::from_parts(parts, body))
        }
    )?;

    Ok(handle_result.map(|()| res))
}

struct Ctx {
    table: ResourceTable,
    wasi: WasiCtx,
    http: DefaultHttpCtx,
}

impl Default for Ctx {
    fn default() -> Self {
        Self {
            table: ResourceTable::default(),
            wasi: WasiCtxBuilder::new().inherit_stdio().build(),
            http: DefaultHttpCtx,
        }
    }
}

impl WasiView for Ctx {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

impl WasiHttpView for Ctx {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView {
            ctx: &mut self.http,
            table: &mut self.table,
        }
    }
}

#[derive(Default)]
struct DefaultHttpCtx;

impl WasiHttpCtx for DefaultHttpCtx {
    fn is_forbidden_header(&mut self, name: &http::header::HeaderName) -> bool {
        DEFAULT_FORBIDDEN_HEADERS.contains(name)
    }

    fn send_request(
        &mut self,
        _request: http::Request<UnsyncBoxBody<Bytes, ErrorCode>>,
        _options: Option<RequestOptions>,
        _fut: Box<dyn Future<Output = Result<(), ErrorCode>> + Send>,
    ) -> Box<
        dyn Future<
            Output = Result<
                (
                    http::Response<UnsyncBoxBody<Bytes, ErrorCode>>,
                    Box<dyn Future<Output = Result<(), ErrorCode>> + Send>,
                ),
                TrappableError<ErrorCode>,
            >,
        > + Send,
    > {
        Box::new(async {
            Err(ErrorCode::InternalError(Some(
                "outbound HTTP not supported".into(),
            ))
            .into())
        })
    }
}
