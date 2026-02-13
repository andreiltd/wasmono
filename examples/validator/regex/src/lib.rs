wit_bindgen::generate!({
    path: "wit/regex.wit",
});

use crate::exports::wasmono::regex::matcher::Guest;
struct Component;

impl Guest for Component {
    fn first_match(regex_pattern: String, text: String) -> String {
        match regex::Regex::new(&regex_pattern) {
            Ok(re) => {
                re.find(&text)
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_default()
            }
            Err(_) => String::new(),
        }
    }
}

export!(Component);

fn main() {}
