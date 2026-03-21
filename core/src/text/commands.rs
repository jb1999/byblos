/// Process voice commands embedded in transcription output.
///
/// Recognized commands:
/// - "delete that" / "scratch that" → signal to remove last output
/// - "new line" / "newline" → \n
/// - "new paragraph" → \n\n
/// - "period" / "full stop" → .
/// - "comma" → ,
/// - "question mark" → ?
/// - "exclamation mark" / "exclamation point" → !
pub fn process_commands(text: &str) -> String {
    let text = replace_command(text, &["new paragraph"], "\n\n");
    let text = replace_command(&text, &["new line", "newline"], "\n");
    let text = replace_command(&text, &["period", "full stop"], ".");
    let text = replace_command(&text, &["comma"], ",");
    let text = replace_command(&text, &["question mark"], "?");
    let text = replace_command(
        &text,
        &["exclamation mark", "exclamation point"],
        "!",
    );

    // "delete that" and "scratch that" are handled at a higher level
    // since they require removing previously typed text.

    text
}

fn replace_command(text: &str, triggers: &[&str], replacement: &str) -> String {
    let mut result = text.to_string();
    let lower = result.to_lowercase();

    for trigger in triggers {
        if let Some(pos) = lower.find(trigger) {
            let end = pos + trigger.len();
            // Remove any surrounding whitespace around the command.
            let start = result[..pos].trim_end().len();
            let end = if result.len() > end {
                end + result[end..].len() - result[end..].trim_start().len()
            } else {
                end
            };
            result = format!("{}{}{}", &result[..start], replacement, &result[end..]);
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_line() {
        assert_eq!(
            process_commands("hello new line world"),
            "hello\nworld"
        );
    }

    #[test]
    fn test_new_paragraph() {
        assert_eq!(
            process_commands("hello new paragraph world"),
            "hello\n\nworld"
        );
    }

    #[test]
    fn test_punctuation_commands() {
        assert_eq!(
            process_commands("is that right question mark"),
            "is that right?"
        );
    }
}
