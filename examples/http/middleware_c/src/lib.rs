#[allow(warnings)]
mod bindings;

use bindings::exports::my::logging_middleware::handler::Guest;
use bindings::wasi::http::handler;

struct LoggingMiddleware;

impl Guest for LoggingMiddleware {
    async fn handle(
        request: handler::Request,
    ) -> Result<handler::Response, handler::ErrorCode> {
        println!(">>>>>>>>>>>>>>>>>> [mdlC] enter");

        let response = handler::handle(request).await?;

        println!("<<<<<<<<<<<<<<<<<< [mdlC] exit");

        Ok(response)
    }
}

bindings::export!(LoggingMiddleware with_types_in bindings);

fn main() {}
