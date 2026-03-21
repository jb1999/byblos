/// Post-process transcribed text: fix capitalization, spacing, and formatting.
pub fn post_process(text: &str) -> String {
    let text = text.trim().to_string();
    let text = fix_capitalization(&text);
    let text = fix_spacing(&text);
    text
}

/// Ensure the first character and characters after sentence-ending punctuation are capitalized.
fn fix_capitalization(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut capitalize_next = true;

    for ch in text.chars() {
        if capitalize_next && ch.is_alphabetic() {
            result.extend(ch.to_uppercase());
            capitalize_next = false;
        } else {
            result.push(ch);
            if ch == '.' || ch == '!' || ch == '?' {
                capitalize_next = true;
            } else if ch != ' ' {
                capitalize_next = false;
            }
        }
    }

    result
}

/// Fix common spacing issues from transcription output.
fn fix_spacing(text: &str) -> String {
    let text = text
        .replace(" .", ".")
        .replace(" ,", ",")
        .replace(" !", "!")
        .replace(" ?", "?")
        .replace(" :", ":")
        .replace(" ;", ";");

    // Collapse multiple spaces.
    let mut result = String::with_capacity(text.len());
    let mut prev_space = false;
    for ch in text.chars() {
        if ch == ' ' {
            if !prev_space {
                result.push(ch);
            }
            prev_space = true;
        } else {
            result.push(ch);
            prev_space = false;
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_capitalization() {
        assert_eq!(
            fix_capitalization("hello world. how are you? fine!"),
            "Hello world. How are you? Fine!"
        );
    }

    #[test]
    fn test_spacing() {
        assert_eq!(fix_spacing("hello , world ."), "hello, world.");
    }

    #[test]
    fn test_post_process() {
        assert_eq!(
            post_process("  hello , world . how are you  "),
            "Hello, world. How are you"
        );
    }
}
