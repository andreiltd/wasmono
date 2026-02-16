#[allow(warnings)]
mod bindings;

use bindings::exports::my::service::handler::Guest;
use bindings::exports::my::service::handler;

use crate::bindings::wasi::http::handler::handle;

pub struct Service;

impl Guest for Service {
    async fn handle(
        request: handler::Request,
    ) -> Result<handler::Response, handler::ErrorCode> {
        println!("                          [svcA] entered!");

        let response = handle(request).await?;

        println!("                          [svcA] received response from svcB!");

        Ok(response)
    }
}

bindings::export!(Service with_types_in bindings);

fn main() {}
