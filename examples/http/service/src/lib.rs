#[allow(warnings)]
mod bindings;

use bindings::exports::wasi::http::handler::Guest;
use bindings::exports::wasi::http::handler;
use bindings::wasi::http::types::{Request, Response};
use bindings::wit_future;

pub struct Service;

impl Guest for Service {
    async fn handle(
        request: handler::Request,
    ) -> Result<handler::Response, handler::ErrorCode> {
        println!("                          [svcB] entered!");

        let headers = request.get_headers().await;

        let (_, result_rx) = wit_future::new(|| Ok(()));
        let (body, trailers) = Request::consume_body(request, result_rx).await;

        Ok(Response::new(headers, Some(body), trailers).await.0)
    }
}

bindings::export!(Service with_types_in bindings);

fn main() {}
