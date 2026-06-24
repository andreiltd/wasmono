#[allow(warnings)]
mod bindings;

use bindings::exports::wasi::http::handler::Guest;
use bindings::wasi::http::handler;

struct LoggingMiddleware;

impl Guest for LoggingMiddleware {
    async fn handle(
        request: handler::Request,
    ) -> Result<handler::Response, handler::ErrorCode> {
        println!(">>>> [mdlA] enter");

        let response = handler::handle(request).await?;

        println!("<<<< [mdlA] exit");

        Ok(response)
    }
}

bindings::export!(LoggingMiddleware with_types_in bindings);

fn main() {}
